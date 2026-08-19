import Foundation

struct TerminalDevelopmentBootstrap: Sendable {
    let host: String
    let sessionID: String
    let credential: String
    let rendererStressChunks: [String]?

    var isComplete: Bool {
        !host.isEmpty && !sessionID.isEmpty && !credential.isEmpty
    }

    static func launchEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalDevelopmentBootstrap {
        #if DEBUG
        let rendererStressChunks = environment["MOCHA_DEV_RENDERER_STRESS_CHUNKS"]
            .flatMap { value in
                try? JSONDecoder().decode([String].self, from: Data(value.utf8))
            }
        return TerminalDevelopmentBootstrap(
            host: environment["MOCHA_DEV_HOST"] ?? "",
            sessionID: environment["MOCHA_DEV_SESSION"] ?? "",
            credential: environment["MOCHA_DEV_TOKEN"] ?? "",
            rendererStressChunks: rendererStressChunks
        )
        #else
        TerminalDevelopmentBootstrap(
            host: "",
            sessionID: "",
            credential: "",
            rendererStressChunks: nil
        )
        #endif
    }
}
