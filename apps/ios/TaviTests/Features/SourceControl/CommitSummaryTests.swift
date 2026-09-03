import Foundation
@testable import Tavi
import Testing

// Commits tab wire shapes and the age words (#78).
struct CommitSummaryTests {
    @Test func logDecodesWithAnUpstreamAndWithout() throws {
        let json = """
        {"path":"/w","branch":"feat/x","base":"main",
         "ahead":[{"sha":"9c2f1a4d9c2f1a4d9c2f1a4d9c2f1a4d9c2f1a4d","summary":"fix(theme): honour reduce-transparency","author":"Claude Code","when":"2026-09-02T19:00:00+06:00"}],
         "behind":[],
         "upstream":{"name":"origin/feat/x","ahead":1,"behind":0},
         "remote":"origin","truncated":false}
        """
        let log = try JSONDecoder().decode(WorktreeLog.self, from: Data(json.utf8))
        #expect(log.ahead.count == 1)
        #expect(log.ahead[0].shortSha == "9c2f1a4")
        #expect(log.upstream?.ahead == 1)
        #expect(log.remote == "origin")

        let lonely = try JSONDecoder().decode(WorktreeLog.self, from: Data("""
        {"path":"/w","branch":null,"base":null,"ahead":[],"behind":[],"upstream":null,"remote":null,"truncated":false}
        """.utf8))
        #expect(lonely.branch == nil)
        #expect(lonely.upstream == nil)
        #expect(lonely.remote == nil)
    }

    @Test func ageReadsAsMinutesHoursDaysThenADate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func commit(secondsAgo: TimeInterval) -> CommitSummary {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return CommitSummary(sha: "a", summary: "s", author: "t", when: formatter.string(from: now.addingTimeInterval(-secondsAgo)))
        }
        #expect(commit(secondsAgo: 5).age(now: now) == "now")
        #expect(commit(secondsAgo: 12 * 60).age(now: now) == "12 min")
        #expect(commit(secondsAgo: 3 * 3600 + 40).age(now: now) == "3 h")
        #expect(commit(secondsAgo: 2 * 86_400).age(now: now) == "2 d")
        #expect(commit(secondsAgo: 60 * 86_400).age(now: now).contains("20"))
        #expect(CommitSummary(sha: "a", summary: "s", author: "t", when: "garbage").age(now: now) == "")
    }
}
