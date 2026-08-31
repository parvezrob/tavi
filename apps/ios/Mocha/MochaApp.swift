import SwiftUI

@main
struct MochaApp: App {
    var body: some Scene {
        WindowGroup {
            // The optional Face ID gate (#51) wraps everything; with the
            // setting off it renders the content untouched.
            AppLockGate {
                SessionsView()
            }
            // Dark-first is the product's visual contract (PRD §7.1).
            // The tint is the cream ink, not the accent: system blue dies,
            // but amber stays reserved for needs-you and the primary CTA —
            // it cannot own the product's core moment and also be the
            // color of every Done button (#54).
            .preferredColorScheme(.dark)
            .tint(MochaTheme.textPrimary)
        }
    }
}
