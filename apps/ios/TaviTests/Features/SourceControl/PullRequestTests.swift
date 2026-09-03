import Foundation
@testable import Tavi
import Testing

// Pull request wire shapes and words (#79).
struct PullRequestTests {
    @Test func statusDecodesWithAndWithoutAPullRequest() throws {
        let with = try JSONDecoder().decode(PullRequestStatus.self, from: Data("""
        {"path":"/w","branch":"feat/x","unpushed":0,"remote":"origin","gh":{"ok":true},
         "pullRequest":{"number":12,"url":"https://github.com/o/r/pull/12","title":"feat: add b","state":"open","isDraft":false,"base":"main",
                        "checks":"passing","review":"approved","additions":2,"deletions":1,"changedFiles":2}}
        """.utf8))
        #expect(with.pullRequest?.stateLine == "#12 · open · into main")
        #expect(with.pullRequest?.signalsLine == "Checks passing · approved")

        let without = try JSONDecoder().decode(PullRequestStatus.self, from: Data("""
        {"path":"/w","branch":"feat/x","pullRequest":null,"unpushed":3,"remote":"origin","gh":{"ok":false,"reason":"gh on this computer is not logged in to GitHub. Run gh auth login there."}}
        """.utf8))
        #expect(without.pullRequest == nil)
        #expect(without.gh.ok == false)
        #expect(without.gh.reason?.contains("not logged in") == true)
    }

    @Test func draftAndSilentPullRequestsReadPlainly() {
        let draft = PullRequestInfo(number: 3, url: "u", title: "t", state: "open", isDraft: true, base: "", checks: "none", review: nil, additions: 0, deletions: 0, changedFiles: 0)
        #expect(draft.stateLine == "#3 · draft")
        #expect(draft.signalsLine == nil)
        let merged = PullRequestInfo(number: 4, url: "u", title: "t", state: "merged", isDraft: true, base: "main", checks: "failing", review: "changes-requested", additions: 0, deletions: 0, changedFiles: 0)
        #expect(merged.stateLine == "#4 · merged · into main")
        #expect(merged.signalsLine == "Checks failing · changes requested")
    }

    @Test func issueBranchNamesAreShortLowercaseAndGitSafe() {
        #expect(IssueSummary(number: 12, title: "Login redirect loops").branchName == "issue/12-login-redirect-loops")
        #expect(IssueSummary(number: 7, title: "  Fix: the (weird) — thing!  ").branchName == "issue/7-fix-the-weird-thing")
        #expect(IssueSummary(number: 9, title: "🚀🚀").branchName == "issue/9")
        let long = IssueSummary(number: 1, title: String(repeating: "word ", count: 20)).branchName
        #expect(long.hasPrefix("issue/1-word-word"))
        #expect(long.count <= "issue/1-".count + 40)
        #expect(!long.hasSuffix("-"))
        // The cap lands on a word boundary, never mid-word.
        #expect(IssueSummary(number: 2, title: "abcdefghij klmnopqrstuvwxyz abcdefghij klmnop").branchName == "issue/2-abcdefghij-klmnopqrstuvwxyz-abcdefghij")
        // A whole word that ends exactly at the cap is kept.
        #expect(IssueSummary(number: 3, title: "session handoff cue show when a pane is also open elsewhere").branchName == "issue/3-session-handoff-cue-show-when-a-pane-is")
        // One word longer than the cap is cut mid-word rather than emptied.
        #expect(IssueSummary(number: 4, title: String(repeating: "x", count: 50)).branchName == "issue/4-" + String(repeating: "x", count: 40))
    }
}
