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
        #expect(summary(agent: "gemini").displayName == "Gemini CLI")
        #expect(summary(agent: "opencode").displayName == "OpenCode")
        #expect(summary(agent: "shell").displayName == "Terminal")
        #expect(summary(agent: "shell").isShell)
        #expect(!summary(agent: "claude").isShell)
        // A kind herdr adds before this map learns it still reads sensibly.
        #expect(summary(agent: "newthing").displayName == "Newthing")
    }

    @Test
    func projectNamePrefersTitleThenDirectoryName() {
        #expect(summary(title: "fix the build").projectName == "fix the build")
        #expect(summary(title: "").projectName == "mocha")
        #expect(summary(agent: "claude", title: "Claude").projectName == "mocha")
        // Herdr's default tab title is the product name; a shell's is its prompt.
        #expect(summary(agent: "claude", title: "Claude Code").projectName == "mocha")
        #expect(summary(agent: "claude", title: "Claude Code").meaningfulTitle == nil)
        #expect(summary(agent: "claude", title: "Claude Code ").meaningfulTitle == nil)
        #expect(summary(agent: "claude", title: "fix the build").meaningfulTitle == "fix the build")
        // A shell's prompt title still names it outside the home, never inside a group.
        #expect(summary(agent: "shell", title: "dev@mac:~/mocha").projectName == "dev@mac:~/mocha")
        #expect(summary(agent: "shell", title: "dev@mac:~/mocha").meaningfulTitle == nil)
        #expect(summary(cwd: "/Users/dev").projectName == "Home")
    }

    @Test
    func abbreviatesTheHomePrefix() {
        #expect(summary(cwd: "/Users/dev/projects/mocha").abbreviatedPath == "~/projects/mocha")
        #expect(summary(cwd: "/home/dev/work").abbreviatedPath == "~/work")
        #expect(summary(cwd: "/opt/tools").abbreviatedPath == "/opt/tools")
    }
}

@MainActor
struct AgentStatusSmootherTests {
    private func agent(_ id: String, _ status: String) -> AgentSummary {
        AgentSummary(
            id: id,
            agent: "claude",
            status: status,
            cwd: "/",
            title: "",
            workspaceId: "w",
            tabId: "t",
            focused: false
        )
    }

    @Test
    func escalationShowsImmediately() {
        let smoother = AgentStatusSmoother(hold: 5)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = smoother.apply([agent("p", "idle")], now: t0)
        let (agents, review) = smoother.apply([agent("p", "blocked")], now: t0.addingTimeInterval(1))
        #expect(agents.first?.status == "blocked")
        #expect(review == nil)
    }

    @Test
    func deescalationIsHeldUntilStable() {
        let smoother = AgentStatusSmoother(hold: 5)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = smoother.apply([agent("p", "blocked")], now: t0)

        let (early, review) = smoother.apply([agent("p", "done")], now: t0.addingTimeInterval(1))
        #expect(early.first?.status == "blocked")
        #expect(review == Date(timeIntervalSince1970: 6))

        let (mid, _) = smoother.apply([agent("p", "done")], now: t0.addingTimeInterval(3))
        #expect(mid.first?.status == "blocked")

        let (late, lateReview) = smoother.apply([agent("p", "done")], now: t0.addingTimeInterval(6.1))
        #expect(late.first?.status == "done")
        #expect(lateReview == nil)
    }

    @Test
    func flappingBackToBlockedResetsTheHold() {
        let smoother = AgentStatusSmoother(hold: 5)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = smoother.apply([agent("p", "blocked")], now: t0)
        _ = smoother.apply([agent("p", "done")], now: t0.addingTimeInterval(1))
        _ = smoother.apply([agent("p", "blocked")], now: t0.addingTimeInterval(2))

        // The earlier 1s de-escalation must not count toward this new one.
        let (agents, review) = smoother.apply([agent("p", "done")], now: t0.addingTimeInterval(4))
        #expect(agents.first?.status == "blocked")
        #expect(review == Date(timeIntervalSince1970: 9))
    }

    @Test
    func workingToDoneIsAlsoHeld() {
        let smoother = AgentStatusSmoother(hold: 5)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = smoother.apply([agent("p", "working")], now: t0)
        let (agents, _) = smoother.apply([agent("p", "done")], now: t0.addingTimeInterval(1))
        #expect(agents.first?.status == "working")
    }

    @Test
    func vanishedAgentsDropTheirState() {
        let smoother = AgentStatusSmoother(hold: 5)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = smoother.apply([agent("p", "blocked")], now: t0)
        _ = smoother.apply([], now: t0.addingTimeInterval(1))
        // Reappearing as done starts fresh — no stale blocked hold.
        let (agents, _) = smoother.apply([agent("p", "done")], now: t0.addingTimeInterval(2))
        #expect(agents.first?.status == "done")
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
