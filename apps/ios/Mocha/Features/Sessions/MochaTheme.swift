import SwiftUI

// Mocha's visual system (PRD §7.1, revised by the #54 design pass; owner
// rejected a warm/cream ramp as too close to Anthropic's own brand):
// dark-first and quiet on *pure graphite* — a strictly achromatic ramp,
// zero hue bias either way, like an instrument panel. One accent: the
// amber that owns "needs you" is also the brand — an indicator lamp on
// graphite, nothing else glows. Every other status is a quiet dot, never
// a text color or a button. Two corner radii, not five. Every color
// decision routes through this type.
enum MochaTheme {
    // Achromatic ramp. The discipline is the identity: not blue-biased
    // default dark, not warm brand-cream — neutral, deep, OLED-true.
    static let canvas = Color(white: 0.051)
    static let card = Color(white: 0.106)
    static let well = Color(white: 0.039)
    static let hairline = Color.white.opacity(0.08)

    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)

    // The one accent. Amber is both the brand and "needs you" — the
    // product's core moment owns its color. Ink for text on amber fills.
    static let accent = Color(red: 0.910, green: 0.639, blue: 0.239)
    static let accentInk = Color(white: 0.08)

    // Status colors are dots and stripes only — never buttons, never body
    // text (the needs-you label is the accent, which is the exception that
    // proves the rule). Working and done are deliberately muted so nothing
    // competes with attention.
    static let statusBlocked = accent
    static let statusWorking = Color(red: 0.553, green: 0.624, blue: 0.722)
    static let statusDone = Color(red: 0.549, green: 0.686, blue: 0.545)
    static let statusIdle = Color(white: 0.46)

    // Two radii: surfaces and controls. Anything else is drift.
    static let cardRadius: CGFloat = 14
    static let wellRadius: CGFloat = 8
    static let stripeWidth: CGFloat = 3
}

// The primary call to action: amber fill, espresso ink. Replaces
// .borderedProminent, whose white-on-tint text fails contrast on amber
// and whose shape drifts from the system's radii.
struct MochaPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(MochaTheme.accentInk.opacity(isEnabled ? 1 : 0.6))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                MochaTheme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.35),
                in: Capsule()
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == MochaPrimaryButtonStyle {
    static var mochaProminent: MochaPrimaryButtonStyle { MochaPrimaryButtonStyle() }
}

// Freshness is telemetry unless it carries a decision: show it while work
// is moving (or waiting on the user), and when a quiet agent has been
// quiet long enough that "how long?" is the next question. An idle row
// touched seconds ago stays silent.
enum FreshnessRule {
    static func shows(status: String, observedAt: Date, now: Date = Date()) -> Bool {
        status == "working" || status == "blocked"
            || now.timeIntervalSince(observedAt) > 5 * 60
    }
}
