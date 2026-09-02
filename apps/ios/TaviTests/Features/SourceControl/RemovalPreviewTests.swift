import Foundation
import Testing
@testable import Tavi

// Remove worktree wire shape and the words it drives (#81) — the choices
// that lose work are pure functions so they are tested here.
struct RemovalPreviewTests {
    private func preview(files: Int = 0, commits: Int = 0, upstream: String? = nil, remote: String? = "origin", merged: Bool = false, agents: Int = 0, branch: String? = "feat/x") throws -> RemovalPreview {
        let agentJSON = (0..<agents).map { "{\"paneId\":\"p\($0)\",\"tabId\":\"t\($0)\",\"kind\":\"claude\",\"status\":\"done\"}" }.joined(separator: ",")
        let json = """
        {"path":"/w","branch":\(branch.map { "\"\($0)\"" } ?? "null"),"isMain":false,"locked":false,"repoRoot":"/r","base":"main",
         "uncommitted":{"files":\(files),"additions":60,"deletions":7},
         "unpushed":{"commits":\(commits),"upstream":\(upstream.map { "\"\($0)\"" } ?? "null"),"remote":\(remote.map { "\"\($0)\"" } ?? "null")},
         "agents":[\(agentJSON)],"branchMerged":\(merged)}
        """
        return try JSONDecoder().decode(RemovalPreview.self, from: Data(json.utf8))
    }

    // herdr closes tabs whole: the host names what else goes (#83); an
    // older host says nothing and the sheet shows nothing.
    @Test func agentsSharingATabAreNamedByFolder() throws {
        #expect(try preview(agents: 1).agentsAlsoClosed.isEmpty)
        let json = """
        {"path":"/w","branch":"feat/x","isMain":false,"locked":false,"repoRoot":"/r","base":"main",
         "uncommitted":{"files":0,"additions":0,"deletions":0},
         "unpushed":{"commits":0,"upstream":"origin/feat/x","remote":"origin"},
         "agents":[{"paneId":"p1","tabId":"t1","kind":"claude","status":"done"}],
         "alsoClosed":[{"paneId":"p2","tabId":"t1","kind":"codex","status":"working","cwd":"/Users/me/Projects/other"}],
         "branchMerged":true}
        """
        let shared = try JSONDecoder().decode(RemovalPreview.self, from: Data(json.utf8))
        #expect(shared.agentsAlsoClosed.map(\.paneId) == ["p2"])
        #expect(RemovalWords.alsoClosedLine(shared.agentsAlsoClosed[0]) == "Codex in other shares that tab and closes with it")
        #expect(RemovalWords.alsoClosedLine(RemovalPreview.Agent(paneId: "p", tabId: "t", kind: "shell", status: "idle", cwd: nil)) == "Terminal in another folder shares that tab and closes with it")
    }

    @Test func amberOnlyWhereNothingIsLost() throws {
        // Uncommitted changes and unpushed commits: no safe path, no amber.
        #expect(RemovalWords.choice(try preview(files: 2, commits: 3)) == .pushAndDiscard)
        // Unpushed only, with a remote: push then remove is safe.
        #expect(RemovalWords.choice(try preview(commits: 3)) == .pushThenRemove)
        // Unpushed with nowhere to push: discard is the only path.
        #expect(RemovalWords.choice(try preview(commits: 3, remote: nil)) == .discardOnly)
        // Uncommitted only: discard is the only path.
        #expect(RemovalWords.choice(try preview(files: 1)) == .discardOnly)
        // Clean and pushed: one amber Remove.
        #expect(RemovalWords.choice(try preview(upstream: "origin/feat/x")) == .safeRemove)
        // Not on a branch with unpushed commits: nothing to push.
        #expect(RemovalWords.choice(try preview(commits: 2, branch: nil)) == .discardOnly)
    }

    @Test func labelsSpellOutTheCounts() throws {
        let both = try preview(files: 2, commits: 3)
        #expect(RemovalWords.discardLabel(both) == "Discard 2 changes and 3 commits")
        #expect(RemovalWords.pushAndDiscardLabel(both) == "Push 3 commits, discard 2 changes")
        #expect(RemovalWords.discardLabel(try preview(files: 1)) == "Discard 1 change")
        #expect(RemovalWords.lead(both) == "This worktree has work that exists nowhere else.")
        #expect(RemovalWords.lead(try preview(upstream: "origin/feat/x")) == "Everything here is committed and pushed.")
    }

    @Test func branchLineMatchesTheHostRule() throws {
        // Merged: goes with the worktree.
        #expect(RemovalWords.branchLine(try preview(merged: true), afterPush: false) == "feat/x is merged into main and goes too")
        // Fully on its upstream but not merged: the host keeps it now.
        #expect(RemovalWords.branchLine(try preview(upstream: "origin/feat/x"), afterPush: false) == "feat/x stays here (it is on origin/feat/x too)")
        // Unpushed commits: kept unless discarded.
        #expect(RemovalWords.branchLine(try preview(commits: 2), afterPush: false) == "feat/x stays here unless you discard its commits")
        // Push first: the branch is safe on the remote, the local copy goes.
        #expect(RemovalWords.branchLine(try preview(commits: 2), afterPush: true) == "feat/x goes here once it is on origin")
        #expect(RemovalWords.branchLine(try preview(branch: nil), afterPush: false) == "Not on a branch")
        #expect(RemovalWords.branchWillBeDeleted(try preview(upstream: "origin/feat/x"), afterPush: false) == false)
        #expect(RemovalWords.branchWillBeDeleted(try preview(commits: 2), afterPush: true) == true)
    }

    @Test func receiptDecodesAndReadsAsSentences() throws {
        let receipt = try JSONDecoder().decode(RemovalReceipt.self, from: Data("""
        {"removed":{"path":"/w","branch":"feat/x","branchDeleted":false,"branchKept":"feat/x","branchNote":"2 commits on feat/x exist nowhere else, so the branch stays.","closedAgents":1,"pushed":0}}
        """.utf8))
        #expect(RemovalWords.receiptLines(receipt) == ["Closed 1 agent that was in it", "2 commits on feat/x exist nowhere else, so the branch stays."])
        let pushed = try JSONDecoder().decode(RemovalReceipt.self, from: Data("""
        {"removed":{"path":"/w","branch":"feat/x","branchDeleted":true,"branchKept":null,"branchNote":null,"closedAgents":0,"pushed":3}}
        """.utf8))
        #expect(RemovalWords.receiptLines(pushed) == ["Pushed 3 commits first", "Deleted the branch feat/x"])
    }

    @Test func hostAnswersBecomeOutcomes() {
        // An old host without the route: a sentence that says to update.
        let old: HostSourceControlClient.Outcome<RemovalReceipt> = HostSourceControlClient.interpret(status: 404, data: Data("{\"error\":\"Not found.\"}".utf8))
        guard case let .failure(reason) = old else { Issue.record("expected failure"); return }
        #expect(reason.contains("too old"))
        // A real refusal keeps the host's sentence and status.
        let refused: HostSourceControlClient.Outcome<RemovalReceipt> = HostSourceControlClient.interpret(status: 409, data: Data("{\"error\":\"feat/x changed since you looked.\"}".utf8))
        guard case let .refused(status, sentence) = refused else { Issue.record("expected refusal"); return }
        #expect(status == 409)
        #expect(sentence == "feat/x changed since you looked.")
        // A 404 that is a sentence about the path stays a refusal.
        let missing: HostSourceControlClient.Outcome<RemovalReceipt> = HostSourceControlClient.interpret(status: 404, data: Data("{\"error\":\"That folder does not exist on this computer.\"}".utf8))
        guard case .refused = missing else { Issue.record("expected refusal"); return }
        #expect(HostSourceControlClient.pullRequestNumber(in: "#12") == 12)
        #expect(HostSourceControlClient.pullRequestNumber(in: "https://github.com/o/r/pull/12") == nil)
    }

    @Test func agentKindsReadAsTheHomeNamesThem() {
        #expect(AgentKindWords.name("claude") == "Claude Code")
        #expect(AgentKindWords.name("shell") == "Terminal")
        #expect(AgentKindWords.name("aider") == "Aider")
        #expect(AgentKindWords.name("") == "An agent")
    }
}
