import Testing
@testable import Tavi

struct TerminalDevelopmentBootstrapTests {
    @Test
    func readsTheAgentPaneToOpenOnLaunch() {
        let none = TerminalDevelopmentBootstrap.launchEnvironment([
            "TAVI_DEV_HOST": "https://mac.tailnet.ts.net",
            "TAVI_DEV_TOKEN": "secret",
        ])
        let blank = TerminalDevelopmentBootstrap.launchEnvironment(["TAVI_DEV_AGENT": ""])
        let pane = TerminalDevelopmentBootstrap.launchEnvironment(["TAVI_DEV_AGENT": "wB:p1"])

        #expect(none.agentPaneID == nil)
        #expect(blank.agentPaneID == nil)
        #expect(pane.agentPaneID == "wB:p1")
        #expect(pane.rendererStressChunks == nil)
    }

    @Test
    func readsTheRendererStressCorpus() {
        let stress = TerminalDevelopmentBootstrap.launchEnvironment([
            "TAVI_DEV_RENDERER_STRESS_CHUNKS": #"["first","second"]"#,
        ])
        let malformed = TerminalDevelopmentBootstrap.launchEnvironment([
            "TAVI_DEV_RENDERER_STRESS_CHUNKS": "not json",
        ])

        #expect(stress.rendererStressChunks == ["first", "second"])
        #expect(stress.agentPaneID == nil)
        #expect(malformed.rendererStressChunks == nil)
    }
}
