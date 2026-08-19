import Testing
@testable import Mocha

struct TerminalDevelopmentBootstrapTests {
    @Test
    func requiresEveryDevelopmentConnectionValue() {
        let incomplete = TerminalDevelopmentBootstrap.launchEnvironment([
            "MOCHA_DEV_HOST": "https://mac.tailnet.ts.net",
            "MOCHA_DEV_SESSION": "session",
        ])
        let complete = TerminalDevelopmentBootstrap.launchEnvironment([
            "MOCHA_DEV_HOST": "https://mac.tailnet.ts.net",
            "MOCHA_DEV_SESSION": "session",
            "MOCHA_DEV_TOKEN": "secret",
        ])

        #expect(!incomplete.isComplete)
        #expect(complete.isComplete)
        #expect(complete.rendererStressChunks == nil)

        let stress = TerminalDevelopmentBootstrap.launchEnvironment([
            "MOCHA_DEV_RENDERER_STRESS_CHUNKS": #"["first","second"]"#,
        ])
        #expect(stress.rendererStressChunks == ["first", "second"])
    }
}
