import SwiftUI

// The home's cards: one folder as one card, and the raised worktree
// groups inside a repository's card.

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
                .padding(.horizontal, TaviTheme.Spacing.tight)
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
                        .padding(.horizontal, TaviTheme.Spacing.card)
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
        .padding(.horizontal, TaviTheme.Spacing.card)
        .padding(.top, TaviTheme.Spacing.snug)
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
                .padding(.horizontal, TaviTheme.Spacing.snug)
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
