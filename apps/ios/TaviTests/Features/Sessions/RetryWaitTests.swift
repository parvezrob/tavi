import Foundation
@testable import Tavi
import Testing

// The retry delay as a wakeable wait (#111), on the manual clock: it must
// end exactly once, and a wake that arrives before the wait it belongs to
// must not spend itself on a later outage.
@MainActor
struct RetryWaitTests {
    private let delay = Duration.seconds(2)

    @MainActor
    private final class Done {
        var value = false
    }

    private func waiting(_ wait: RetryWait, dial: Int) -> (Task<Void, Never>, Done) {
        let done = Done()
        let delay = delay
        let task = Task { @MainActor in
            await wait.sleep(delay, dial: dial)
            done.value = true
        }
        return (task, done)
    }

    @Test func theTimerEndsAWaitNobodyWakes() async throws {
        let clock = ManualTerminalClock()
        let (task, done) = waiting(RetryWait(timing: clock.timing), dial: 1)
        defer { task.cancel() }

        try await waitFor { await clock.hasWaiter(for: self.delay) }
        #expect(!done.value)
        try await clock.resumeAll(for: delay)
        try await waitFor { done.value }
    }

    // `stop()` cancels the stream task and the wait on one turn; the task's
    // cancellation callback lands a turn later, by which time a reconfigured
    // link may already be sitting out its own first delay. The replacement
    // registers from this task, synchronously, so the callback is guaranteed
    // to find it pending.
    @Test func aCancelledWaitsLateCallbackDoesNotReleaseItsReplacement() async throws {
        let clock = ManualTerminalClock()
        let wait = RetryWait(timing: clock.timing)
        let (first, _) = waiting(wait, dial: 1)
        try await waitFor { await clock.hasWaiter(for: self.delay) }

        first.cancel()
        wait.cancel()
        let resumedByClock = Done()
        let delay = delay
        let timer = Task { @MainActor in
            await settle()
            resumedByClock.value = true
            try? await clock.resumeAll(for: delay)
        }
        defer { timer.cancel() }
        await wait.sleep(delay, dial: 2)
        #expect(resumedByClock.value)
    }

    @Test func aWakeForThisDialEndsTheWaitEarly() async throws {
        let clock = ManualTerminalClock()
        let wait = RetryWait(timing: clock.timing)
        let (task, done) = waiting(wait, dial: 7)
        defer { task.cancel() }

        try await waitFor { await clock.hasWaiter(for: self.delay) }
        wait.wake(dial: 7)
        try await waitFor { done.value }
        // The timer it beat is released with it, not left to fire into the
        // next dial.
        try await waitFor { await clock.hasWaiter(for: self.delay) == false }
    }

    // The path handler can wake the link before the dial it belongs to has
    // finished unwinding.
    @Test func aWakeThatArrivesFirstIsHonouredByThatDialsWait() async throws {
        let clock = ManualTerminalClock()
        let wait = RetryWait(timing: clock.timing)
        wait.wake(dial: 7)
        let (task, done) = waiting(wait, dial: 7)
        defer { task.cancel() }

        try await waitFor { done.value }
        #expect(await clock.timesScheduled(delay) == 0)
    }

    @Test func aWakeForAnotherDialIsDiscardedRatherThanCarried() async throws {
        let clock = ManualTerminalClock()
        let wait = RetryWait(timing: clock.timing)
        wait.wake(dial: 6)
        let (task, done) = waiting(wait, dial: 7)
        defer { task.cancel() }

        try await waitFor { await clock.hasWaiter(for: self.delay) }
        #expect(!done.value)
        try await clock.resumeAll(for: delay)
        try await waitFor { done.value }
    }

    @Test func aCreditIsSpentByOneWaitOnly() async throws {
        let clock = ManualTerminalClock()
        let wait = RetryWait(timing: clock.timing)
        wait.wake(dial: 7)
        let (first, firstDone) = waiting(wait, dial: 7)
        defer { first.cancel() }
        try await waitFor { firstDone.value }

        let (second, secondDone) = waiting(wait, dial: 7)
        defer { second.cancel() }
        try await waitFor { await clock.hasWaiter(for: self.delay) }
        #expect(!secondDone.value)
    }

    @Test func cancelReleasesThePendingWait() async throws {
        let clock = ManualTerminalClock()
        let wait = RetryWait(timing: clock.timing)
        let (task, done) = waiting(wait, dial: 7)
        defer { task.cancel() }

        try await waitFor { await clock.hasWaiter(for: self.delay) }
        wait.cancel()
        try await waitFor { done.value }
    }

    @Test func cancelForgetsTheCredit() async throws {
        let clock = ManualTerminalClock()
        let wait = RetryWait(timing: clock.timing)
        wait.wake(dial: 7)
        wait.cancel()
        let (task, done) = waiting(wait, dial: 7)
        defer { task.cancel() }

        try await waitFor { await clock.hasWaiter(for: self.delay) }
        #expect(!done.value)
    }

    // The ordering the plan names: the wait times out, the wake lands before
    // the next dial has ended, and the wait that follows that later dial
    // carries a newer tag — so the credit is discarded there and that outage
    // waits its own delay out.
    @Test func aWakeThatArrivesBetweenTwoDialsIsDiscardedByTheNextWait() async throws {
        let clock = ManualTerminalClock()
        let wait = RetryWait(timing: clock.timing)
        let (first, firstDone) = waiting(wait, dial: 7)
        defer { first.cancel() }
        try await waitFor { await clock.hasWaiter(for: self.delay) }
        try await clock.resumeAll(for: delay)
        try await waitFor { firstDone.value }

        wait.wake(dial: 7)
        let (second, secondDone) = waiting(wait, dial: 8)
        defer { second.cancel() }
        try await waitFor { await clock.hasWaiter(for: self.delay) }
        #expect(!secondDone.value)
        try await clock.resumeAll(for: delay)
        try await waitFor { secondDone.value }
    }

    // The stream loop's own cancellation check does the rest, as it does
    // today with a cancelled sleep.
    @Test func aCancelledTaskIsReleased() async throws {
        let clock = ManualTerminalClock()
        let (task, done) = waiting(RetryWait(timing: clock.timing), dial: 7)

        try await waitFor { await clock.hasWaiter(for: self.delay) }
        task.cancel()
        try await waitFor { done.value }
    }
}
