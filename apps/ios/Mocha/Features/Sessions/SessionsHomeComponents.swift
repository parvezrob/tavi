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
                    Text(status.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(status.color)
                }

                HStack(spacing: 8) {
                    Text(agent.projectName)
                        .font(.footnote)
                        .foregroundStyle(MochaTheme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let observedAt {
                        FreshnessLabel(observedAt: observedAt)
                    }
                }

                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.caption2)
                    Text(agent.abbreviatedPath)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .foregroundStyle(MochaTheme.textSecondary.opacity(0.8))

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
                    Text(agent.projectName)
                        .font(.caption)
                        .foregroundStyle(MochaTheme.textSecondary)
                        .lineLimit(1)
                    Text(agent.abbreviatedPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(MochaTheme.textSecondary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 8)
                if let observedAt {
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
