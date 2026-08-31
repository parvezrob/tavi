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
            // Dark-first is the product's visual contract (PRD §7.1);
            // the terminal and home surfaces are designed for it. The
            // global tint is the one brand accent (#54) — system blue is
            // the color of an unconsidered app.
            .preferredColorScheme(.dark)
            .tint(MochaTheme.accent)
        }
    }
}
