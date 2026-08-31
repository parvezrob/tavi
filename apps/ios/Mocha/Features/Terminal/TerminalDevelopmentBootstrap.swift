import Foundation

// Launch-environment hooks for scripted simulator runs and the UI tests.
// Only DEBUG builds read them; a release build sees nothing (#33). The host
// and token themselves are seeded by SessionsView from MOCHA_DEV_HOST and
// MOCHA_DEV_TOKEN, so the terminal always opens on the paired host.
struct TerminalDevelopmentBootstrap: Sendable {
    // MOCHA_DEV_AGENT: the herdr pane whose terminal opens straight from
    // launch, without a tap on the home.
    let agentPaneID: String?
    // MOCHA_DEV_RENDERER_STRESS_CHUNKS: a JSON array of output chunks the
    // terminal replays into its renderer in a loop.
    let rendererStressChunks: [String]?

    static func launchEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalDevelopmentBootstrap {
        #if DEBUG
        let agentPaneID = environment["MOCHA_DEV_AGENT"].flatMap { $0.isEmpty ? nil : $0 }
        let rendererStressChunks = environment["MOCHA_DEV_RENDERER_STRESS_CHUNKS"]
            .flatMap { value in
                try? JSONDecoder().decode([String].self, from: Data(value.utf8))
            }
        return TerminalDevelopmentBootstrap(
            agentPaneID: agentPaneID,
            rendererStressChunks: rendererStressChunks
        )
        #else
        TerminalDevelopmentBootstrap(agentPaneID: nil, rendererStressChunks: nil)
        #endif
    }
}
