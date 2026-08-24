import Foundation
import Testing
@testable import Mocha

struct AgentPresentationTests {
    private func summary(
        agent: String = "claude",
        status: String = "working",
        cwd: String = "/Users/dev/projects/mocha",
        title: String = ""
    ) -> AgentSummary {
        AgentSummary(
            id: "pane-1",
            agent: agent,
            status: status,
            cwd: cwd,
            title: title,
            workspaceId: "ws-1",
            tabId: "tab-1",
            focused: false
        )
    }

    @Test
    func partitionsStatusesIntoHomeSections() {
        #expect(summary(status: "blocked").homeSection == .needsYou)
        #expect(summary(status: "working").homeSection == .active)
        #expect(summary(status: "done").homeSection == .recent)
        #expect(summary(status: "idle").homeSection == .recent)
        #expect(summary(status: "something-new").homeSection == .recent)
    }

    @Test
    func labelsUnknownStatusHonestly() {
        #expect(AgentStatusStyle.of("something-new").label == "Unknown")
        #expect(AgentStatusStyle.of("blocked").label == "Needs you")
        #expect(AgentStatusStyle.of("working").label == "Working")
    }

    @Test
    func displayNamesAreRecognizableProducts() {
        #expect(summary(agent: "claude").displayName == "Claude Code")
        #expect(summary(agent: "codex").displayName == "Codex")
        #expect(summary(agent: "gemini").displayName == "Gemini")
    }

    @Test
    func projectNamePrefersTitleThenDirectoryName() {
        #expect(summary(title: "fix the build").projectName == "fix the build")
        #expect(summary(title: "").projectName == "mocha")
        #expect(summary(agent: "claude", title: "Claude").projectName == "mocha")
    }
}

struct AgentPreviewFormatterTests {
    @Test
    func stripsAnsiColorAndCursorSequences() {
        let raw = "\u{1B}[32mPASS\u{1B}[0m tests/unit\n\u{1B}[2K\u{1B}[1Gdone"
        #expect(AgentPreviewFormatter.sanitize(raw) == "PASS tests/unit\ndone")
    }

    @Test
    func stripsOscTitleSequences() {
        let raw = "\u{1B}]0;window title\u{07}visible text"
        #expect(AgentPreviewFormatter.sanitize(raw) == "visible text")
    }

    @Test
    func removesControlCharactersButKeepsTabs() {
        let raw = "col1\tcol2\u{08}\u{0D}\nnext"
        #expect(AgentPreviewFormatter.sanitize(raw) == "col1\tcol2\nnext")
    }

    @Test
    func trimsBlankEdgesAndKeepsTheLastLines() {
        let raw = "\n\n one \ntwo\nthree\nfour\nfive\n\n\n"
        #expect(AgentPreviewFormatter.sanitize(raw, maxLines: 3) == "three\nfour\nfive")
    }

    @Test
    func emptyAndWhitespaceInputBecomesEmpty() {
        #expect(AgentPreviewFormatter.sanitize("") == "")
        #expect(AgentPreviewFormatter.sanitize(" \n \n") == "")
    }
}
