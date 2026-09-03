import Foundation
@testable import Tavi
import Testing

struct AgentPresentationTests {
    // #55: a tab label is identity only when a person plausibly chose it.
    @Test
    func keepsUserChosenTabNamesAndDropsHerdrDefaults() {
        #expect(Fixtures.agentSummary(tabLabel: "fix auth bug").userTabName == "fix auth bug")
        #expect(Fixtures.agentSummary(tabLabel: "  spaced  ").userTabName == "spaced")
        #expect(Fixtures.agentSummary(tabLabel: nil).userTabName == nil)
        #expect(Fixtures.agentSummary(tabLabel: "").userTabName == nil)
        #expect(Fixtures.agentSummary(tabLabel: "3").userTabName == nil)
        #expect(Fixtures.agentSummary(tabLabel: "claude").userTabName == nil)
        #expect(Fixtures.agentSummary(tabLabel: "Claude Code").userTabName == nil)
        #expect(Fixtures.agentSummary(tabLabel: "tavi claude").userTabName == nil)
        #expect(Fixtures.agentSummary(agent: "shell", tabLabel: "tavi terminal").userTabName == nil)
        // Tabs created before the rename (#62) carry the old prefix.
        #expect(Fixtures.agentSummary(tabLabel: "mocha claude").userTabName == nil)
        // Phone-created defaults of any kind, and the pane's own command
        // line, are not names (#50 live pass).
        #expect(Fixtures.agentSummary(tabLabel: "mocha terminal").userTabName == nil)
        #expect(Fixtures.agentSummary(tabLabel: "tavi terminal").userTabName == nil)
        #expect(Fixtures.agentSummary(tabLabel: "claude --resume abc").userTabName == nil)
        #expect(Fixtures.agentSummary(tabLabel: "claude").userTabName == nil)
        #expect(Fixtures.agentSummary(tabLabel: "npm run dev -- --port 3000").userTabName == nil)
        #expect(Fixtures.agentSummary(tabLabel: "--dangerously-skip").userTabName == nil)
        #expect(Fixtures.agentSummary(tabLabel: "claude-review").userTabName == "claude-review")
        #expect(Fixtures.agentSummary(agent: "shell", tabLabel: "mocha terminal").userTabName == nil)
        // "tavi" leading a real name is still the user's name.
        #expect(Fixtures.agentSummary(tabLabel: "tavi redesign").userTabName == "tavi redesign")
    }

    @Test
    func secondaryIdentityPrefersTheUsersNameOverTheAgentsTitle() {
        #expect(Fixtures.agentSummary(title: "Fixing the tests", tabLabel: "ship v2").secondaryIdentity == "ship v2")
        #expect(Fixtures.agentSummary(title: "Fixing the tests").secondaryIdentity == "Fixing the tests")
        // A shell's title is its prompt — never identity; the user's tab
        // name still is.
        #expect(Fixtures.agentSummary(agent: "shell", title: "user@host:~").secondaryIdentity == nil)
        #expect(Fixtures.agentSummary(agent: "shell", title: "user@host:~", tabLabel: "deploy box").secondaryIdentity == "deploy box")
    }

    @Test
    func partitionsStatusesIntoHomeSections() {
        #expect(Fixtures.agentSummary(status: "blocked").homeSection == .needsYou)
        #expect(Fixtures.agentSummary(status: "working").homeSection == .active)
        #expect(Fixtures.agentSummary(status: "done").homeSection == .recent)
        #expect(Fixtures.agentSummary(status: "idle").homeSection == .recent)
        #expect(Fixtures.agentSummary(status: "something-new").homeSection == .recent)
    }

    @Test
    func labelsUnknownStatusHonestly() {
        #expect(AgentStatusStyle.of("something-new").label == "Unknown")
        #expect(AgentStatusStyle.of("blocked").label == "Needs you")
        #expect(AgentStatusStyle.of("working").label == "Working")
    }

    @Test
    func displayNamesAreRecognizableProducts() {
        #expect(Fixtures.agentSummary(agent: "claude").displayName == "Claude Code")
        #expect(Fixtures.agentSummary(agent: "codex").displayName == "Codex")
        #expect(Fixtures.agentSummary(agent: "gemini").displayName == "Gemini CLI")
        #expect(Fixtures.agentSummary(agent: "opencode").displayName == "OpenCode")
        #expect(Fixtures.agentSummary(agent: "shell").displayName == "Terminal")
        #expect(Fixtures.agentSummary(agent: "shell").isShell)
        #expect(!Fixtures.agentSummary(agent: "claude").isShell)
        // A kind herdr adds before this map learns it still reads sensibly.
        #expect(Fixtures.agentSummary(agent: "newthing").displayName == "Newthing")
    }

    @Test
    func projectNamePrefersTitleThenDirectoryName() {
        #expect(Fixtures.agentSummary(title: "fix the build").projectName == "fix the build")
        #expect(Fixtures.agentSummary(title: "").projectName == "tavi")
        #expect(Fixtures.agentSummary(agent: "claude", title: "Claude").projectName == "tavi")
        // Herdr's default tab title is the product name; a shell's is its prompt.
        #expect(Fixtures.agentSummary(agent: "claude", title: "Claude Code").projectName == "tavi")
        #expect(Fixtures.agentSummary(agent: "claude", title: "Claude Code").meaningfulTitle == nil)
        #expect(Fixtures.agentSummary(agent: "claude", title: "Claude Code ").meaningfulTitle == nil)
        #expect(Fixtures.agentSummary(agent: "claude", title: "fix the build").meaningfulTitle == "fix the build")
        // A shell's prompt title still names it outside the home, never inside a group.
        #expect(Fixtures.agentSummary(agent: "shell", title: "dev@mac:~/tavi").projectName == "dev@mac:~/tavi")
        #expect(Fixtures.agentSummary(agent: "shell", title: "dev@mac:~/tavi").meaningfulTitle == nil)
        #expect(Fixtures.agentSummary(cwd: "/Users/dev").projectName == "Home")
    }

    @Test
    func abbreviatesTheHomePrefix() {
        #expect(Fixtures.agentSummary(cwd: "/Users/dev/projects/tavi").abbreviatedPath == "~/projects/tavi")
        #expect(Fixtures.agentSummary(cwd: "/home/dev/work").abbreviatedPath == "~/work")
        #expect(Fixtures.agentSummary(cwd: "/opt/tools").abbreviatedPath == "/opt/tools")
    }
}

@MainActor
struct AgentStatusSmootherTests {
    private func agent(_ id: String, _ status: String) -> AgentSummary {
        Fixtures.agentSummary(id: id, status: status, cwd: "/")
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
