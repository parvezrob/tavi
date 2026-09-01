import Foundation
import Testing
@testable import Tavi

// Freshness shows when it carries a decision (#54): moving or waiting work
// always, finished work always ("did it just finish?"), and idle only once
// it has been quiet long enough that "how long?" is the question.
struct FreshnessRuleTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test
    func movingAndWaitingWorkAlwaysShowFreshness() {
        #expect(FreshnessRule.shows(status: "working", observedAt: now, now: now))
        #expect(FreshnessRule.shows(status: "blocked", observedAt: now, now: now))
    }

    @Test
    func finishedWorkShowsFreshnessImmediately() {
        #expect(FreshnessRule.shows(status: "done", observedAt: now.addingTimeInterval(-30), now: now))
    }

    @Test
    func aFreshIdleRowStaysQuietUntilItIsActuallyStale() {
        #expect(!FreshnessRule.shows(status: "idle", observedAt: now.addingTimeInterval(-30), now: now))
        #expect(!FreshnessRule.shows(status: "idle", observedAt: now.addingTimeInterval(-299), now: now))
        #expect(FreshnessRule.shows(status: "idle", observedAt: now.addingTimeInterval(-301), now: now))
    }
}
