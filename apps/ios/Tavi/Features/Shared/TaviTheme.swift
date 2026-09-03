import SwiftUI

// Tavi's visual system (PRD §7.1, revised by the #54 design pass; owner
// rejected a warm/cream ramp as too close to Anthropic's own brand):
// dark-first and quiet on *pure graphite* — a strictly achromatic ramp,
// zero hue bias either way, like an instrument panel. One accent: the
// amber that owns "needs you" is also the brand — an indicator lamp on
// graphite, nothing else glows. Every other status is a quiet dot, never
// a text color or a button. Two corner radii, not five. Every color
// decision routes through this type.
enum TaviTheme {
    // Achromatic ramp. The discipline is the identity: not blue-biased
    // default dark, not warm brand-cream — neutral, deep, OLED-true.
    static let canvas = Color(white: 0.051)
    static let card = Color(white: 0.106)
    static let well = Color(white: 0.039)
    static let hairline = Color.white.opacity(0.08)
    // A raised group inside a card (#74): a hair lighter than the card with
    // a one-point highlight along its top edge — iOS 26 separates grouped
    // content with material, not strokes, so nothing inside a card draws a
    // hairline. The well is the sunken counterpart.
    static let groupFill = Color.white.opacity(0.045)
    static let groupHighlight = Color.white.opacity(0.06)

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
    // Deletions in a diff, and nothing else: a diff without red is not a
    // diff anyone can read. Muted to sit beside statusDone, never a button.
    static let diffRemoved = Color(red: 0.788, green: 0.463, blue: 0.443)

    // Two radii: surfaces and controls. Anything else is drift.
    static let cardRadius: CGFloat = 14
    static let wellRadius: CGFloat = 8
    static let stripeWidth: CGFloat = 3

    // The four steps the screens actually stand on, counted from the
    // paddings already written (#100); anything else is a one-off that
    // has to say why in place.
    enum Spacing {
        // Air between raised groups, and inside a pill.
        static let tight: CGFloat = 6
        // Inside a row: the gap that separates lines of one thought.
        static let snug: CGFloat = 12
        // A card's own inset, which is also the radius it is cut with, and
        // the air it keeps between the blocks it stacks.
        static let card: CGFloat = 14
        // The margin of a screen or a sheet.
        static let screen: CGFloat = 16
        // 8 and 20 are deliberately not steps (counted 2026-09-04, #104):
        // 8 is 39 sites — an inline gap beside a glyph, a header over its
        // cards, a pill's own vertical padding — and 20 is 17 — a block's
        // inset, air above a control, the home's gap between sections.
        // Neither is one role, so a name for either would look like a
        // decision nothing made.
    }
}

// The primary call to action: amber fill, espresso ink. Replaces
// .borderedProminent, whose white-on-tint text fails contrast on amber
// and whose shape drifts from the system's radii.
struct TaviPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(TaviTheme.accentInk.opacity(isEnabled ? 1 : 0.6))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                TaviTheme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.35),
                in: Capsule()
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == TaviPrimaryButtonStyle {
    static var taviProminent: TaviPrimaryButtonStyle { TaviPrimaryButtonStyle() }
}

// Freshness is telemetry unless it carries a decision: show it while work
// is moving (or waiting on the user), and for finished work — "did it just
// finish?" is exactly what the home is asked. Only an idle row touched
// moments ago stays silent; once it has been quiet a while, "how long?"
// becomes the question again.
enum FreshnessRule {
    static func shows(status: String, observedAt: Date, now: Date = Date()) -> Bool {
        status != "idle" || now.timeIntervalSince(observedAt) > 5 * 60
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
