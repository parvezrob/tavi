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
            .padding(.vertical, TaviTheme.Spacing.snug)
            .padding(.horizontal, TaviTheme.Spacing.card)
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
                        .padding(.horizontal, TaviTheme.Spacing.tight)
                        .padding(.vertical, 1)
                        .background(TaviTheme.accent, in: Capsule())
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(TaviTheme.textSecondary.opacity(0.6))
                }
            }
            .padding(.vertical, TaviTheme.Spacing.snug)
            .padding(.horizontal, TaviTheme.Spacing.card)
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
            .padding(.trailing, TaviTheme.Spacing.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(primary), \(agent.displayName), \(status.label)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("sessions.agent.\(agent.id)")
    }
}

// Needs-you is flat and first, across every computer and project: a
// waiting agent never hides under a group. Said once — the header carries
// the count, the rows carry the agents; there is no banner repeating
// either (home v3). Row identity includes the status so a section move
// rebuilds the row instead of reusing a cached one. A row opens the
// decision sheet (approve/deny without the terminal).
struct NeedsYouSection: View {
    let agents: [AgentSummary]
    let computerName: (AgentSummary) -> String?
    let preview: (AgentSummary) -> String?
    let observedAt: (AgentSummary) -> Date?
    @Binding var expandedStacks: Set<String>
    let onSelect: (AgentSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Needs you", count: agents.count > 1 ? agents.count : nil, countTint: TaviTheme.accent)
                .accessibilityIdentifier("sessions.needsYou")
            let groups = HomeGrouping.waitingGroups(agents) { agent in
                NeedsYouRow.askingLine(in: preview(agent))
            }
            VStack(spacing: 0) {
                ForEach(groups) { group in
                    if group.isStacked {
                        WaitingStackRow(
                            group: group,
                            computerName: computerName(group.primary),
                            isExpanded: expandedStacks.contains(group.key)
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if expandedStacks.remove(group.key) == nil {
                                    expandedStacks.insert(group.key)
                                }
                            }
                        }
                        if expandedStacks.contains(group.key) {
                            ForEach(group.agents, id: \.cardIdentity) { agent in
                                Divider().overlay(TaviTheme.hairline).padding(.leading, 60)
                                row(agent, computerName: nil, primaryOverride: agent.tabLabel ?? agent.id)
                                    .padding(.leading, TaviTheme.Spacing.screen)
                            }
                        }
                    } else {
                        row(group.primary, computerName: computerName(group.primary), primaryOverride: nil)
                    }
                    if group.id != groups.last?.id {
                        Divider().overlay(TaviTheme.hairline).padding(.leading, 60)
                    }
                }
            }
            .taviCard()
        }
    }

    private func row(_ agent: AgentSummary, computerName: String?, primaryOverride: String?) -> some View {
        NeedsYouRow(
            agent: agent,
            preview: preview(agent),
            observedAt: observedAt(agent),
            computerName: computerName,
            primaryOverride: primaryOverride
        ) {
            onSelect(agent)
        }
    }
}
