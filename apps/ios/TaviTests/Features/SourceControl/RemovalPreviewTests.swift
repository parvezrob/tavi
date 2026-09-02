import Foundation
import Testing
@testable import Tavi

// Remove worktree wire shape and the words it drives (#81).
struct RemovalPreviewTests {
    private func preview(files: Int = 0, commits: Int = 0, upstream: String? = nil, remote: String? = "origin", merged: Bool = false, agents: Int = 0) throws -> RemovalPreview {
        let agentJSON = (0..<agents).map { "{\"paneId\":\"p\($0)\",\"tabId\":\"t\($0)\",\"kind\":\"claude\",\"status\":\"done\"}" }.joined(separator: ",")
        let json = """
        {"path":"/w","branch":"feat/x","isMain":false,"repoRoot":"/r","base":"main",
         "uncommitted":{"files":\(files),"additions":60,"deletions":7},
         "unpushed":{"commits":\(commits),"upstream":\(upstream.map { "\"\($0)\"" } ?? "null"),"remote":\(remote.map { "\"\($0)\"" } ?? "null")},
         "agents":[\(agentJSON)],"branchMerged":\(merged)}
        """
        return try JSONDecoder().decode(RemovalPreview.self, from: Data(json.utf8))
    }

    @Test func dirtyUnpushedWorktreeOffersThePushPathFirst() throws {
        let dirty = try preview(files: 2, commits: 3, agents: 1)
        #expect(dirty.isSafe == false)
        #expect(dirty.canPushFirst == true)
        #expect(dirty.remote == "origin")
        #expect(dirty.agents.count == 1)
    }

    @Test func cleanPushedWorktreeIsSafeAndNoRemoteMeansNoPush() throws {
        let clean = try preview(upstream: "origin/feat/x", merged: true)
        #expect(clean.isSafe == true)
        #expect(clean.canPushFirst == false)
        #expect(clean.remote == "origin/feat/x")

        let lonely = try preview(commits: 2, remote: nil)
        #expect(lonely.isSafe == false)
        #expect(lonely.canPushFirst == false)
        #expect(lonely.remote == nil)
    }

    @Test func agentKindsReadAsTheHomeNamesThem() {
        #expect(AgentKindWords.name("claude") == "Claude Code")
        #expect(AgentKindWords.name("shell") == "Terminal")
        #expect(AgentKindWords.name("aider") == "Aider")
        #expect(AgentKindWords.name("") == "An agent")
    }
}
