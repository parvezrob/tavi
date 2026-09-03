import Foundation
@testable import Tavi
import Testing

struct AgentPresentationTests {
    private func summary(
        agent: String = "claude",
        status: String = "working",
        cwd: String = "/Users/dev/projects/tavi",
        title: String = "",
        tabLabel: String? = nil
    ) -> AgentSummary {
        AgentSummary(
            id: "pane-1",
            agent: agent,
            status: status,
            cwd: cwd,
            title: title,
            workspaceId: "ws-1",
            tabId: "tab-1",
            tabLabel: tabLabel,
            focused: false
        )
    }

    // #55: a tab label is identity only when a person plausibly chose it.
    @Test
    func keepsUserChosenTabNamesAndDropsHerdrDefaults() {
        #expect(summary(tabLabel: "fix auth bug").userTabName == "fix auth bug")
        #expect(summary(tabLabel: "  spaced  ").userTabName == "spaced")
        #expect(summary(tabLabel: nil).userTabName == nil)
        #expect(summary(tabLabel: "").userTabName == nil)
        #expect(summary(tabLabel: "3").userTabName == nil)
        #expect(summary(tabLabel: "claude").userTabName == nil)
        #expect(summary(tabLabel: "Claude Code").userTabName == nil)
        #expect(summary(tabLabel: "tavi claude").userTabName == nil)
        #expect(summary(agent: "shell", tabLabel: "tavi terminal").userTabName == nil)
        // Tabs created before the rename (#62) carry the old prefix.
        #expect(summary(tabLabel: "mocha claude").userTabName == nil)
        // Phone-created defaults of any kind, and the pane's own command
        // line, are not names (#50 live pass).
        #expect(summary(tabLabel: "mocha terminal").userTabName == nil)
        #expect(summary(tabLabel: "tavi terminal").userTabName == nil)
        #expect(summary(tabLabel: "claude --resume abc").userTabName == nil)
        #expect(summary(tabLabel: "claude").userTabName == nil)
        #expect(summary(tabLabel: "npm run dev -- --port 3000").userTabName == nil)
        #expect(summary(tabLabel: "--dangerously-skip").userTabName == nil)
        #expect(summary(tabLabel: "claude-review").userTabName == "claude-review")
        #expect(summary(agent: "shell", tabLabel: "mocha terminal").userTabName == nil)
        // "tavi" leading a real name is still the user's name.
        #expect(summary(tabLabel: "tavi redesign").userTabName == "tavi redesign")
    }

    @Test
    func secondaryIdentityPrefersTheUsersNameOverTheAgentsTitle() {
        #expect(summary(title: "Fixing the tests", tabLabel: "ship v2").secondaryIdentity == "ship v2")
        #expect(summary(title: "Fixing the tests").secondaryIdentity == "Fixing the tests")
        // A shell's title is its prompt — never identity; the user's tab
        // name still is.
        #expect(summary(agent: "shell", title: "user@host:~").secondaryIdentity == nil)
        #expect(summary(agent: "shell", title: "user@host:~", tabLabel: "deploy box").secondaryIdentity == "deploy box")
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
        #expect(summary(title: "").projectName == "tavi")
        #expect(summary(agent: "claude", title: "Claude").projectName == "tavi")
        // Herdr's default tab title is the product name; a shell's is its prompt.
        #expect(summary(agent: "claude", title: "Claude Code").projectName == "tavi")
        #expect(summary(agent: "claude", title: "Claude Code").meaningfulTitle == nil)
        #expect(summary(agent: "claude", title: "Claude Code ").meaningfulTitle == nil)
        #expect(summary(agent: "claude", title: "fix the build").meaningfulTitle == "fix the build")
        // A shell's prompt title still names it outside the home, never inside a group.
        #expect(summary(agent: "shell", title: "dev@mac:~/tavi").projectName == "dev@mac:~/tavi")
        #expect(summary(agent: "shell", title: "dev@mac:~/tavi").meaningfulTitle == nil)
        #expect(summary(cwd: "/Users/dev").projectName == "Home")
    }

    @Test
    func abbreviatesTheHomePrefix() {
        #expect(summary(cwd: "/Users/dev/projects/tavi").abbreviatedPath == "~/projects/tavi")
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
