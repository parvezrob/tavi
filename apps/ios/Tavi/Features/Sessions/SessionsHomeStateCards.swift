import SwiftUI

// What the home shows when it has agents to talk about but none to list:
// connecting, asleep, refusing, unpaired, idle. One shape for all five
// (#100) — a glyph, the sentence, sometimes a quieter second line, and
// sometimes the one action that answers it.
struct StateCard<Actions: View>: View {
    // A spinner while the computer is still answering, a symbol when the
    // card states a fact, nothing when the card is only an offer.
    enum Icon {
        case none
        case progress
        case symbol(String, Color)
    }

    // A card of one sentence centres its glyph beside it; a card that says
    // more hangs the glyph off the first line.
    enum Layout {
        case oneLine
        case stacked
    }

    let icon: Icon
    let title: String
    let detail: String?
    let stripe: Color?
    let layout: Layout
    let actions: Actions

    init(
        icon: Icon,
        title: String,
        detail: String? = nil,
        stripe: Color? = nil,
        layout: Layout = .stacked,
        @ViewBuilder actions: () -> Actions
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.stripe = stripe
        self.layout = layout
        self.actions = actions()
    }

    // A card with a glyph states a fact; one that is only waiting or only
    // offering speaks in the quiet register.
    private var titleColor: Color {
        if case .symbol = icon { return TaviTheme.textPrimary }
        return TaviTheme.textSecondary
    }

    // Lines of one thought sit close; buttons stand further off, and
    // furthest when the card is nothing but that offer (PRD §7.15).
    private var contentSpacing: CGFloat {
        if detail != nil { return TaviTheme.Spacing.tight }
        if case .none = icon { return TaviTheme.Spacing.card }
        return 8
    }

    var body: some View {
        Group {
            if case .none = icon {
                lines
            } else {
                HStack(alignment: layout == .oneLine ? .center : .top, spacing: 10) {
                    glyph
                    lines
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(TaviTheme.Spacing.card)
        .taviCard(stripe: stripe)
    }

    @ViewBuilder
    private var glyph: some View {
        if case .progress = icon {
            ProgressView()
        } else if case let .symbol(name, tint) = icon {
            Image(systemName: name)
                .foregroundStyle(tint)
        }
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            Text(title)
                .font(.callout)
                .foregroundStyle(titleColor)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(TaviTheme.textSecondary)
            }
            actions
        }
    }
}

extension StateCard where Actions == EmptyView {
    init(icon: Icon, title: String, detail: String? = nil, stripe: Color? = nil, layout: Layout = .stacked) {
        self.init(icon: icon, title: title, detail: detail, stripe: stripe, layout: layout) { EmptyView() }
    }
}

// A computer in trouble says so once, in one quiet line: what is on screen
// below it is the last state it reported, not the present.
struct LastKnownBanner: View {
    let computer: HomeComputer

    var body: some View {
        HStack(spacing: 8) {
            if computer.health == .stale {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "moon.zzz")
                    .font(.caption)
            }
            Text(
                computer.health == .stale
                    ? "Reconnecting — showing the last known state"
                    : "\(computer.name) isn't answering — showing the last known state"
            )
            .font(.caption)
            .foregroundStyle(TaviTheme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TaviTheme.Spacing.card)
        .padding(.vertical, 8)
        .taviCard()
        .accessibilityIdentifier("sessions.stale")
    }
}

// First run leads with the promise, not the absence (#54): what Tavi
// is for, then the one step, then the trust line that used to hide in
// the pairing sheet's footer.
struct NoHostCard: View {
    let onScan: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("Your agents, in your pocket")
                .font(.title3.weight(.semibold))
                .foregroundStyle(TaviTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text("Your agents and logins stay on your own computer. Pair it once by scanning the code it shows.")
                .font(.footnote)
                .foregroundStyle(TaviTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button(action: onScan) {
                Label("Scan pairing code", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.taviProminent)
            .padding(.top, TaviTheme.Spacing.tight)
            .accessibilityIdentifier("sessions.scanPairingCode")
            Label("No provider login. No public relay.", systemImage: "lock")
                .font(.caption2)
                .foregroundStyle(TaviTheme.textSecondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, TaviTheme.Spacing.screen)
        .taviCard()
    }
}

// Whatever is not projects: a computer that is still connecting, cannot be
// reached, has no usable feed, or was unpaired — one card each.
struct ComputerStateCard: View {
    let computer: HomeComputer
    let onPairAgain: () -> Void
    let onRemove: () -> Void

    @ViewBuilder
    var body: some View {
        if computer.health == .revoked {
            revoked
        } else if !computer.hasLoaded {
            if computer.health == .offline {
                offline
            } else {
                loading
            }
        } else if !computer.available {
            unavailable
        }
    }

    private var loading: some View {
        StateCard(icon: .progress, title: "Connecting to \(computer.name)…", layout: .oneLine)
            .accessibilityIdentifier("sessions.loading")
    }

    // The computer does not answer at all and nothing was ever shown for
    // it. Once something has loaded, the last known state stays on screen
    // under the "Offline" header instead (PRD §7.8).
    private var offline: some View {
        StateCard(
            icon: .symbol("moon.zzz", TaviTheme.textSecondary),
            title: "\(computer.name) isn't answering. It may be asleep or not on your Tailscale network.",
            detail: "Tavi keeps trying on its own."
        )
        .accessibilityIdentifier("sessions.offline")
    }

    private var unavailable: some View {
        StateCard(
            icon: .symbol("exclamationmark.triangle", TaviTheme.statusBlocked),
            title: computer.reason ?? "Waiting for \(computer.name).",
            detail: "Tavi keeps retrying on its own.",
            stripe: TaviTheme.statusBlocked
        )
        .accessibilityIdentifier("sessions.agentsUnavailable")
    }

    // The credential is dead on the host side (#46); nothing on this phone
    // can revive it, so the offers are pairing again or letting it go. The
    // other computers are untouched either way (#50). Pair again keeps the
    // record until the new pairing lands — cancelling the scan must not
    // silently lose the computer — and the same fingerprint replaces it.
    private var revoked: some View {
        StateCard(
            icon: .symbol("person.crop.circle.badge.xmark", TaviTheme.statusBlocked),
            title: computer.reason ?? "This iPhone is no longer paired with \(computer.name).",
            stripe: TaviTheme.statusBlocked
        ) {
            HStack(spacing: 10) {
                Button("Pair again", action: onPairAgain)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("sessions.pairAgain")
                Button("Remove", action: onRemove)
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(TaviTheme.textSecondary)
                    .accessibilityIdentifier("sessions.removeHost")
            }
        }
        .accessibilityIdentifier("sessions.revoked")
    }
}

// Nothing is running: say so, and offer the one next step on the card
// itself (#52) — amber, because it is the screen's only action.
struct IdleCard: View {
    let computers: [HomeComputer]
    let onNewAgent: () -> Void

    var body: some View {
        StateCard(
            icon: .none,
            title: computers.count == 1
                ? "No agents are running on \(computers[0].name) right now."
                : "No agents are running on your computers right now."
        ) {
            Button(action: onNewAgent) {
                Label("New agent", systemImage: "plus")
            }
            .buttonStyle(.taviProminent)
            .accessibilityIdentifier("sessions.idle.newAgent")
        }
        .accessibilityIdentifier("sessions.idle")
    }
}
