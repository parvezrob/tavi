import SwiftUI

@main
struct MochaApp: App {
    var body: some Scene {
        WindowGroup {
            SessionsView()
                // Dark-first is the product's visual contract (PRD §7.1);
                // the terminal and home surfaces are designed for it.
                .preferredColorScheme(.dark)
        }
    }
}
