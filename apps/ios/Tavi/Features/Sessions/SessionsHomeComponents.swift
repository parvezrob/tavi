// Over the 400-line line; split in #69.
// swiftlint:disable file_length

import SwiftUI

// Building blocks of the Sessions home (home v3, 2026-09-02). The home is
// two kinds of object and nothing else: a labelled section, and a card of
// rows. Every row has the same skeleton — a glyph tile that says which
// kind of agent it is, a primary line that says which one (your name for
// it, else its folder), a quiet secondary line, and one trailing fact.
// Colour is spent once: amber on what needs you. Every colour comes from
// TaviTheme so the surface stays a single instrument panel.

// Which kind of agent, as a glyph on a small tile. The tile is the row's
// anchor: five Claude Codes in a column no longer need the words "Claude
// Code" five times, and the tint carries the state — amber while it waits
// on you, quiet otherwise.
struct AgentGlyphTile: View {
    let agent: AgentSummary
    var tint: Color = TaviTheme.textSecondary

    var body: some View {
        Image(systemName: agent.kindGlyph)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(TaviTheme.well, in: RoundedRectangle(cornerRadius: TaviTheme.wellRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}

// One waiting agent. Primary: your name for it, else its folder — the
// line most likely to tell two waiting agents apart. Secondary: the kind,
// and the computer when several are on screen. Third, when the host has
// one: the question, in the agent's own words. Trailing: how long it has
// waited. No chevron — the tap opens the decision sheet, not a screen.
struct NeedsYouRow: View {
    let agent: AgentSummary
    let preview: String?
    let observedAt: Date?
    var computerName: String? = nil
    // Inside an expanded stack the folder is already on the stack's row,
    // so the member row shows the only thing left that differs: herdr's
    // raw tab label, else the pane id.
    var primaryOverride: String? = nil
    let action: () -> Void

    private var primary: String { primaryOverride ?? agent.secondaryIdentity ?? agent.projectName }

    private var secondary: String {
        [agent.displayName, computerName].compactMap { $0 }.joined(separator: " · ")
    }

    private var askingLine: String? { Self.askingLine(in: preview) }

    // The last non-empty line of the sanitized preview: the question, in
    // the agent's own words, when there is one on screen.
    static func askingLine(in preview: String?) -> String? {
        preview?
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                AgentGlyphTile(agent: agent, tint: TaviTheme.statusBlocked)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(primary)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(TaviTheme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let observedAt {
                            FreshnessLabel(observedAt: observedAt)
                        }
                    }
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(TaviTheme.textSecondary)
                        .lineLimit(1)
                    if let askingLine {
                        Text(askingLine)
                            .font(.footnote)
                            .foregroundStyle(TaviTheme.textPrimary.opacity(0.8))
                            .lineLimit(1)
                            .padding(.top, 3)
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(primary), \(secondary), needs you")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("sessions.agent.\(agent.id)")
    }
}

// Several waiting agents the phone cannot tell apart, as one row: the
// tile is drawn stacked, the secondary line says how many and that there
// is nothing on their screens, the trailing numeral is the count. A tap
// expands the stack in place to its member rows; it never picks one.
struct WaitingStackRow: View {
    let group: WaitingGroup
    var computerName: String? = nil
    let isExpanded: Bool
    let action: () -> Void

    private var primary: String { group.primary.secondaryIdentity ?? group.primary.projectName }

    private var secondary: String {
        var parts = [group.primary.displayName]
        if let computerName { parts.append(computerName) }
        let count = "\(group.agents.count) waiting"
        parts.append(group.askingLine == nil ? "\(count), nothing on screen" : count)
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                AgentGlyphTile(agent: group.primary, tint: TaviTheme.statusBlocked)
                    .background(alignment: .topTrailing) {
                        // Two more tiles peeking out behind: a stack, at a glance.
                        RoundedRectangle(cornerRadius: TaviTheme.wellRadius, style: .continuous)
                            .strokeBorder(TaviTheme.textSecondary.opacity(0.35), lineWidth: 1)
                            .frame(width: 34, height: 34)
                            .offset(x: 3, y: -3)
                    }
                    .background(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: TaviTheme.wellRadius, style: .continuous)
                            .strokeBorder(TaviTheme.textSecondary.opacity(0.2), lineWidth: 1)
                            .frame(width: 34, height: 34)
                            .offset(x: 6, y: -6)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(primary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TaviTheme.textPrimary)
                        .lineLimit(1)
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(TaviTheme.textSecondary)
                        .lineLimit(1)
                    if let askingLine = group.askingLine {
                        Text(askingLine)
                            .font(.footnote)
                            .foregroundStyle(TaviTheme.textPrimary.opacity(0.8))
                            .lineLimit(1)
                            .padding(.top, 3)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Text("\(group.agents.count)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(TaviTheme.accentInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(TaviTheme.accent, in: Capsule())
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(TaviTheme.textSecondary.opacity(0.6))
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(primary), \(secondary)")
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("sessions.waitingStack.\(group.primary.id)")
    }
}

// One folder as one card: its name and computer on top, its agents as
// rows beneath. A running agent's row carries a short excerpt of its
// screen; done and idle rows are a single line. The path stays — a
// folder name alone never stands in for a place — but as the quiet
// second line of the header, said once per folder.
struct ProjectCard: View {
    let project: HomeProject
    // Named when several computers are on screen (#50): two machines can
    // hold the same folder.
    var computerName: String? = nil
    let preview: (AgentSummary) -> String?
    let observedAt: (AgentSummary) -> Date?
    let onOpen: (AgentSummary) -> Void
    // Long-press: what this agent changed (#25), without opening its terminal.
    var onShowFiles: ((AgentSummary) -> Void)? = nil
    // Long-press: the dev server running in this folder, on the phone (#58).
    var onShowPreview: ((AgentSummary) -> Void)? = nil
    // The card's last row when it is a repository (#74): start something in
    // a new worktree of it.
    var onNewWorktree: ((HomeProject) -> Void)? = nil
    // Tap on a worktree's header: its Source Control (#77).
    var onOpenWorktree: ((HomeWorktree) -> Void)? = nil

    private var agents: [AgentSummary] { project.active + project.recent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(TaviTheme.hairline)
            if project.isRepository {
                // Worktrees as raised groups, 6 pt of air between them and
                // no hairline anywhere inside the card (approved design,
                // PRD §7.12): material separates, strokes don't.
                VStack(spacing: 6) {
                    ForEach(project.worktrees) { worktree in
                        WorktreeGroup(worktree: worktree, preview: preview, observedAt: observedAt, onOpen: onOpen, onShowFiles: onShowFiles, onShowPreview: onShowPreview, onOpenWorktree: onOpenWorktree)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 8)
                if let onNewWorktree {
                    Button {
                        onNewWorktree(project)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .semibold))
                            Text("New worktree")
                                .font(.subheadline)
                        }
                        .foregroundStyle(TaviTheme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sessions.project.newWorktree.\(project.path)")
                } else {
                    Color.clear.frame(height: 8)
                }
            } else {
                ForEach(agents, id: \.cardIdentity) { agent in
                    agentRow(agent)
                    if agent.cardIdentity != agents.last?.cardIdentity {
                        Divider().overlay(TaviTheme.hairline).padding(.leading, 60)
                    }
                }
            }
        }
        .taviCard()
    }

    private func agentRow(_ agent: AgentSummary) -> some View {
        ProjectAgentRow(agent: agent, preview: preview(agent), observedAt: observedAt(agent)) {
            onOpen(agent)
        }
        .contextMenu {
            if let onShowFiles {
                Button("What it changed", systemImage: "doc.text.magnifyingglass") { onShowFiles(agent) }
            }
            if let onShowPreview {
                Button("Preview dev server", systemImage: "globe") { onShowPreview(agent) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TaviTheme.textPrimary)
                    .lineLimit(1)
                Text(project.abbreviatedPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TaviTheme.textSecondary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let computerName {
                Text(computerName)
                    .font(.caption)
                    .foregroundStyle(TaviTheme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("sessions.project.\(project.path)")
        .accessibilityValue(computerName ?? "")
    }
}

// One worktree inside a repository's card (#74): a raised group — a hair
// lighter than the card with a one-point highlight along its top — whose
// header is the branch and its git state, and whose rows are the agents
// living under it, indented one step. The chevron and the tap arrive with
// Source Control (#73 part 3); until then the header is a label.
struct WorktreeGroup: View {
    let worktree: HomeWorktree
    let preview: (AgentSummary) -> String?
    let observedAt: (AgentSummary) -> Date?
    let onOpen: (AgentSummary) -> Void
    var onShowFiles: ((AgentSummary) -> Void)? = nil
    var onShowPreview: ((AgentSummary) -> Void)? = nil
    // Tap on the header: this worktree's Source Control (#77).
    var onOpenWorktree: ((HomeWorktree) -> Void)? = nil

    private var agents: [AgentSummary] { worktree.active + worktree.recent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                onOpenWorktree?(worktree)
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TaviTheme.textSecondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(worktree.info.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(TaviTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !worktree.info.summary.isEmpty {
                            Text(worktree.info.summary)
                                .font(.footnote)
                                .foregroundStyle(TaviTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if onOpenWorktree != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(TaviTheme.textSecondary.opacity(0.6))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 11)
                .padding(.bottom, agents.isEmpty ? 11 : 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onOpenWorktree == nil)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("sessions.worktree.\(worktree.info.path)")
            ForEach(agents, id: \.cardIdentity) { agent in
                ProjectAgentRow(agent: agent, preview: preview(agent), observedAt: observedAt(agent), leadingInset: 24) {
                    onOpen(agent)
                }
                .contextMenu {
                    if let onShowFiles {
                        Button("What it changed", systemImage: "doc.text.magnifyingglass") { onShowFiles(agent) }
                    }
                    if let onShowPreview {
                        Button("Preview dev server", systemImage: "globe") { onShowPreview(agent) }
                    }
                }
            }
        }
        .background(TaviTheme.groupFill, in: RoundedRectangle(cornerRadius: TaviTheme.wellRadius, style: .continuous))
        .overlay {
            // The top-edge highlight that makes the group read as raised: a
            // 1 pt stroke that fades out down the first 16 pt of the sides,
            // so the corners stay 1 pt (a flat 1.5 pt slice through the
            // curve thickened them), and drawn only — a tap at the group's
            // edge must reach the row beneath, not a ring (PRD §7.15).
            RoundedRectangle(cornerRadius: TaviTheme.wellRadius, style: .continuous)
                .strokeBorder(TaviTheme.groupHighlight, lineWidth: 1)
                .mask(alignment: .top) {
                    LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: TaviTheme.wellRadius * 2)
                }
                .allowsHitTesting(false)
        }
    }
}

// One agent under its folder. Primary: your name for it or its own
// title, else the kind. The kind repeats as the second line only when
// something else took the first. Trailing: the status word for Working
// and Done — Idle is the resting state and says nothing, its tile dims
// instead (owner call 2026-09-02) — then how long ago, and the chevron
// that says this row pushes the terminal.
struct ProjectAgentRow: View {
    let agent: AgentSummary
    let preview: String?
    let observedAt: Date?
    // Extra leading room when the row sits inside a worktree group (#74).
    var leadingInset: CGFloat = 0
    let action: () -> Void

    private var status: AgentStatusStyle { .of(agent.status) }
    private var primary: String { agent.secondaryIdentity ?? agent.displayName }
    private var secondary: String? { agent.secondaryIdentity == nil ? nil : agent.displayName }
    private var isRunning: Bool { agent.homeSection == .active }
    private var isIdle: Bool { agent.status == "idle" }

    private var tileTint: Color {
        if isRunning { return TaviTheme.statusWorking }
        return isIdle ? TaviTheme.textSecondary.opacity(0.45) : TaviTheme.textSecondary
    }

    private var showsFreshness: Bool {
        observedAt.map { FreshnessRule.shows(status: agent.status, observedAt: $0) } ?? false
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    AgentGlyphTile(agent: agent, tint: tileTint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(primary)
                            .font(.subheadline.weight(isRunning ? .semibold : .regular))
                            .foregroundStyle(TaviTheme.textPrimary)
                            .lineLimit(1)
                        if let secondary {
                            Text(secondary)
                                .font(.caption)
                                .foregroundStyle(TaviTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 8) {
                        if !isIdle {
                            Text(status.label)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(isRunning ? status.color : TaviTheme.textSecondary)
                        }
                        if let observedAt, showsFreshness, !isRunning {
                            FreshnessLabel(observedAt: observedAt)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(TaviTheme.textSecondary.opacity(0.6))
                    }
                }
                if isRunning, let preview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TaviTheme.textSecondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(TaviTheme.well, in: RoundedRectangle(cornerRadius: TaviTheme.wellRadius, style: .continuous))
                }
            }
            .padding(.vertical, 11)
            .padding(.leading, 14 + leadingInset)
            .padding(.trailing, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(primary), \(agent.displayName), \(status.label)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("sessions.agent.\(agent.id)")
    }
}

// One computer per chip (#50), in the strip at the top of the home: the
// dot is its health, the word after the name is the health when it is
// anything but live, and the amber numeral is how many of its agents are
// waiting on you — so the strip is also the fleet at a glance. A tap
// filters the home to that computer. With one computer the strip is a
// single pill that opens the computer's sheet, and the numeral stays off:
// the "Needs you" header right beneath already says it.
struct ComputerChip: View {
    let computer: HomeComputer
    let isSelected: Bool
    var showsWaitingCount = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if computer.health == .stale || computer.health == .connecting {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill(HostHealthLabel.color(for: computer.health))
                        .frame(width: 6, height: 6)
                }
                Text(computer.name)
                    .font(.footnote.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)
                if computer.health != .live {
                    Text("· \(computer.health.label(latencyMilliseconds: nil, connection: computer.connection))")
                        .font(.footnote)
                        .foregroundStyle(HostHealthLabel.color(for: computer.health))
                        .lineLimit(1)
                }
                if showsWaitingCount, computer.waitingCount > 0 {
                    Text("\(computer.waitingCount)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(TaviTheme.accentInk)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(TaviTheme.accent, in: Capsule())
                }
            }
            .foregroundStyle(isSelected ? TaviTheme.textPrimary : TaviTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? TaviTheme.card : TaviTheme.canvas, in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? TaviTheme.textSecondary.opacity(0.5) : TaviTheme.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(computer.name)
        .accessibilityValue(computer.summary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("sessions.computer.\(computer.id)")
    }
}

// "All" — every computer at once; the default, and the only chip that is
// not a computer.
struct AllComputersChip: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("All")
                .font(.footnote.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? TaviTheme.textPrimary : TaviTheme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? TaviTheme.card : TaviTheme.canvas, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? TaviTheme.textSecondary.opacity(0.5) : TaviTheme.hairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("sessions.computer.all")
    }
}

// Health as a dot and a word; the round trip joins it only while live,
// because a number next to "Offline" would be a lie about the present.
struct HostHealthLabel: View {
    let health: HostHealth
    let latencyMilliseconds: Int?
    var connection: ConnectionPath = .unknown

    var body: some View {
        HStack(spacing: 5) {
            if health == .stale || health == .connecting {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(Self.color(for: health))
                    .frame(width: 6, height: 6)
            }
            Text(health.label(latencyMilliseconds: latencyMilliseconds, connection: connection))
                .font(.caption2)
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(health == .live ? TaviTheme.textSecondary.opacity(0.75) : Self.color(for: health))
        .accessibilityIdentifier("sessions.health.\(Self.identifier(for: health))")
    }

    static func color(for health: HostHealth) -> Color {
        switch health {
        case .live: TaviTheme.statusDone
        case .connecting, .stale: TaviTheme.textSecondary
        case .offline: TaviTheme.statusIdle
        case .revoked: TaviTheme.statusBlocked
        }
    }

    private static func identifier(for health: HostHealth) -> String {
        switch health {
        case .connecting: "connecting"
        case .live: "live"
        case .stale: "stale"
        case .offline: "offline"
        case .revoked: "revoked"
        }
    }
}

// How long since the phone observed the status — which is all the client
// can honestly claim. Words only: a clock glyph repeated down a list was
// texture, not information.
struct FreshnessLabel: View {
    let observedAt: Date

    var body: some View {
        Text(observedAt, style: .relative)
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(TaviTheme.textSecondary)
            .lineLimit(1)
    }
}

private struct TaviCardModifier: ViewModifier {
    let stripe: Color?

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TaviTheme.card)
            .overlay(alignment: .leading) {
                if let stripe {
                    Rectangle()
                        .fill(stripe)
                        .frame(width: TaviTheme.stripeWidth)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: TaviTheme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: TaviTheme.cardRadius, style: .continuous)
                    .strokeBorder(TaviTheme.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func taviCard(stripe: Color? = nil) -> some View {
        modifier(TaviCardModifier(stripe: stripe))
    }
}

extension HostHealth {
    // The word on the header; the round trip joins it only while live.
    func label(latencyMilliseconds: Int?, connection: ConnectionPath = .unknown) -> String {
        switch self {
        case .connecting: "Connecting…"
        case .live: ["Live", latencyMilliseconds.map { "\($0) ms" }, connection.headerSuffix].compactMap { $0 }.joined(separator: " · ")
        case .stale: "Reconnecting"
        case .offline: "Offline"
        case .revoked: "Unpaired"
        }
    }
}
