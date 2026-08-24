import SwiftUI

// Mocha's visual system (PRD §7.1): dark-first, Orca-clean — near-black
// canvas, quiet charcoal groups, hairline borders, system typography, and
// sparse semantic color. Every color decision on the home surface routes
// through this type so the palette stays coherent as surfaces are added.
enum MochaTheme {
    static let canvas = Color(red: 0.047, green: 0.051, blue: 0.063)
    static let card = Color(red: 0.090, green: 0.094, blue: 0.114)
    static let well = Color(red: 0.055, green: 0.059, blue: 0.075)
    static let hairline = Color.white.opacity(0.07)

    static let textPrimary = Color.white.opacity(0.93)
    static let textSecondary = Color.white.opacity(0.55)

    static let statusBlocked = Color(red: 0.910, green: 0.639, blue: 0.239)
    static let statusWorking = Color(red: 0.357, green: 0.608, blue: 1.0)
    static let statusDone = Color(red: 0.275, green: 0.761, blue: 0.443)
    static let statusIdle = Color(red: 0.494, green: 0.510, blue: 0.549)

    static let cardRadius: CGFloat = 14
    static let wellRadius: CGFloat = 8
    static let stripeWidth: CGFloat = 3
}
