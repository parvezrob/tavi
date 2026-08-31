import SwiftUI

// Building blocks of the Sessions home. Each card is a single tap target
// whose accessibility label reads as one sentence, and every color comes
// from MochaTheme so the surface stays quiet and coherent.

struct SectionEyebrow: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .kerning(1.1)
            .textCase(.uppercase)
            .foregroundStyle(MochaTheme.textSecondary)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

// One-line summary of everything blocked, pinned above the sections; the
// tap is the fastest route to the first agent that is waiting on the user.
struct NeedsYouBanner: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MochaTheme.statusBlocked)
                Text("Needs you")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MochaTheme.textPrimary)
                Spacer(minLength: 8)
                Text("^[\(count) waiting](inflect: true)")
                    .font(.subheadline)
                    .foregroundStyle(MochaTheme.statusBlocked)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MochaTheme.textSecondary)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
            .mochaCard(stripe: MochaTheme.statusBlocked)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sessions.needsYou")
    }
}

// Full card for needs-you and active agents: identity, status, freshness,
// and a short sanitized excerpt of the live terminal.
struct AgentCard: View {
    let agent: AgentSummary
    let preview: String?
    let observedAt: Date?
    // Under a project header the folder is already on screen; the card then
    // shows only the agent's own title, if it set one. Cards in the flat
    // needs-you list keep the full location.
    var showsLocation = true
    let action: () -> Void

    private var status: AgentStatusStyle { .of(agent.status) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 8, height: 8)
                    Text(agent.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MochaTheme.textPrimary)
                    Spacer(minLength: 8)
                    // A blocked card already says "needs you" twice — the
                    // amber stripe and its place in the flat list — so the
                    // word would be a third telling (#54). Running cards
                    // keep theirs: the dot alone can't say "Working".
                    if agent.homeSection != .needsYou {
                        Text(status.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(status.color)
                    }
                }

                let showsFreshness = observedAt.map {
                    FreshnessRule.shows(status: agent.status, observedAt: $0)
                } ?? false
                if showsLocation || agent.secondaryIdentity != nil || showsFreshness {
                    HStack(spacing: 8) {
                        if showsLocation {
                            Text(agent.userTabName ?? agent.projectName)
                                .font(.footnote)
                                .foregroundStyle(MochaTheme.textSecondary)
                                .lineLimit(1)
                        } else if let title = agent.secondaryIdentity {
                            Text(title)
                                .font(.footnote)
                                .foregroundStyle(MochaTheme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let observedAt, showsFreshness {
                            FreshnessLabel(observedAt: observedAt)
                        }
                    }
                }

                if showsLocation {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.caption2)
                        Text(agent.abbreviatedPath)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .foregroundStyle(MochaTheme.textSecondary.opacity(0.8))
                }

                if let preview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(MochaTheme.textSecondary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            MochaTheme.well,
                            in: RoundedRectangle(cornerRadius: MochaTheme.wellRadius, style: .continuous)
                        )
                }
            }
            .padding(14)
            .mochaCard(stripe: status.color)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agent.displayName), \(agent.projectName), \(status.label)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("sessions.agent.\(agent.id)")
    }
}

// Compact row for done and idle agents; several rows share one card.
// Always under a project header, so the folder is not repeated; the
// status word is, because a dot alone cannot tell Done from Idle.
struct RecentAgentRow: View {
    let agent: AgentSummary
    let observedAt: Date?
    let action: () -> Void

    private var status: AgentStatusStyle { .of(agent.status) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle()
                    .fill(status.color)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.displayName)
                        .font(.subheadline)
                        .foregroundStyle(MochaTheme.textPrimary)
                    // The user's own name for the task (#55) is what tells
                    // four same-kind rows apart — #52's honest answer.
                    if let title = agent.secondaryIdentity {
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(MochaTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(status.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(status.color)
                if let observedAt, FreshnessRule.shows(status: agent.status, observedAt: observedAt) {
                    FreshnessLabel(observedAt: observedAt)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MochaTheme.textSecondary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agent.displayName), \(agent.projectName), \(status.label)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("sessions.agent.\(agent.id)")
    }
}

// The computer an agent runs on (#26). One paired host today, so this is a
// single quiet line; when a second host arrives (#50) the same header
// separates them.
struct ComputerHeader: View {
    let computer: HomeComputer

    var body: some View {
        // A landmark, not a headline (#54): the smallest, dimmest label on
        // the screen — project names carry the hierarchy below it.
        HStack(spacing: 6) {
            Image(systemName: "desktopcomputer")
                .font(.caption2)
            Text(computer.name)
                .font(.caption2.weight(.medium))
                .kerning(0.8)
                .textCase(.uppercase)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(MochaTheme.textSecondary.opacity(0.75))
        .padding(.top, 14)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("sessions.computer.\(computer.id)")
    }
}

// A project is a folder agents live in: its name leads, the path is the
// quiet second line, and the count says how much is going on there.
struct ProjectHeader: View {
    let project: HomeProject

    // Plain text on purpose: "^[…](inflect:)" only inflects when the Text
    // is built from a literal key; a String var takes the verbatim overload
    // and renders the markup itself. Always the total, then what is going
    // on, so two headers on one screen count the same thing.
    private var summary: String {
        var parts = [project.agentCount == 1 ? "1 agent" : "\(project.agentCount) agents"]
        if !project.active.isEmpty { parts.append("\(project.active.count) running") }
        if !project.needsYou.isEmpty { parts.append("\(project.needsYou.count) waiting above") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MochaTheme.textPrimary)
                    .lineLimit(1)
                Text(project.abbreviatedPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(MochaTheme.textSecondary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text(summary)
                .font(.caption)
                .foregroundStyle(MochaTheme.textSecondary)
        }
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("sessions.project.\(project.path)")
    }
}

// "Seen" is deliberate: this clock starts when the phone observed the
// status, which is all the client can honestly claim.
struct FreshnessLabel: View {
    let observedAt: Date

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock")
                .font(.caption2)
            Text(observedAt, style: .relative)
                .font(.caption2)
                .monospacedDigit()
        }
        .foregroundStyle(MochaTheme.textSecondary)
    }
}

private struct MochaCardModifier: ViewModifier {
    let stripe: Color?

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MochaTheme.card)
            .overlay(alignment: .leading) {
                if let stripe {
                    Rectangle()
                        .fill(stripe)
                        .frame(width: MochaTheme.stripeWidth)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: MochaTheme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MochaTheme.cardRadius, style: .continuous)
                    .strokeBorder(MochaTheme.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func mochaCard(stripe: Color? = nil) -> some View {
        modifier(MochaCardModifier(stripe: stripe))
    }
}
