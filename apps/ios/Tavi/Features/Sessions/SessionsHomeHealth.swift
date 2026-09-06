import SwiftUI

// How the home says when it last heard from a computer, and how long
// ago it observed an agent.

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

    // Shared with the home's computer strip, which draws the same health as
    // a bare dot inside one accessibility element of its own (#111).
    static func identifier(for health: HostHealth) -> String {
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
