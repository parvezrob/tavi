import Foundation
@testable import Tavi
import Testing

// The events stream's watchdog (#86, #107), through the real HostConnection
// with a socket whose arrivals and ping the test owns. The whole policy is
// the production one; the idle marks are crossed by moving the link's clock,
// so nothing here waits out a real 45 seconds. Only the connect deadline is
// lengthened, so that the one wait this suite releases by its length is the
// watchdog's poll and never the link's 5 s deadline.
@MainActor
struct HostEventsWatchdogTests {
    // The reproduced defect: awaiting the ping inline stopped the loop
    // reaching its own cycle check, so a socket 51 s idle had been pinged
    // once and cancelled never. The ping is owned, not awaited.
    @Test
    func aPingThatNeverReturnsDoesNotStopTheWatchdogCyclingAtItsDeadline() async throws {
        let clock = ManualTerminalClock()
        let socket = WatchdogSocket(lastActivity: clock.timing.now(), pingSuspends: true)
        let connection = try eventsLink(socket, clock)
        defer {
            connection.stop()
            socket.releasePings()
        }

        clock.advance(by: .seconds(21))
        try await pollWatchdog(clock)
        try await waitFor { socket.pings == 1 }
        #expect(socket.goingAwayCancels == 0)

        clock.advance(by: .seconds(15))
        try await releaseWatchdogPoll(clock)
        try await waitFor { socket.goingAwayCancels >= 1 }
        #expect(socket.pings == 1)
    }

    // A challenge that ignores cancellation stays this link's until it
    // finishes. Activity must not orphan it and let the next quiet period
    // start another (#107).
    @Test
    func aPingThatIgnoresCancellationIsNeverMultipliedByActivity() async throws {
        let clock = ManualTerminalClock()
        let socket = WatchdogSocket(lastActivity: clock.timing.now(), pingSuspends: true)
        let connection = try eventsLink(socket, clock)
        defer {
            connection.stop()
            socket.releasePings()
        }

        clock.advance(by: .seconds(21))
        try await pollWatchdog(clock)
        try await waitFor { socket.pings == 1 }
        for _ in 0..<3 {
            socket.arrive(at: clock.timing.now())
            try await pollWatchdog(clock)
            clock.advance(by: .seconds(21))
            try await pollWatchdog(clock)
        }
        #expect(socket.pings == 1)

        // And teardown still cycles the socket, which is what releases the
        // real connection's send.
        clock.advance(by: .seconds(15))
        try await releaseWatchdogPoll(clock)
        try await waitFor { socket.goingAwayCancels >= 1 }
        #expect(socket.pings == 1)
    }

    // A socket that keeps answering is never pinged and never cycled.
    @Test
    func aSocketThatKeepsAnsweringIsLeftAlone() async throws {
        let clock = ManualTerminalClock()
        let socket = WatchdogSocket(lastActivity: clock.timing.now())
        let connection = try eventsLink(socket, clock)
        defer { connection.stop() }

        for _ in 0..<20 {
            clock.advance(by: .seconds(5))
            socket.deliver(Fixtures.agentsFrame(), at: clock.timing.now())
            try await pollWatchdog(clock)
        }
        #expect(socket.pings == 0)
        #expect(socket.goingAwayCancels == 0)
    }

    // A challenge that completes releases the slot, so the next quiet
    // period is challenged too.
    @Test
    func aSocketThatGoesQuietTwiceIsChallengedTwice() async throws {
        let clock = ManualTerminalClock()
        let socket = WatchdogSocket(lastActivity: clock.timing.now())
        let connection = try eventsLink(socket, clock)
        defer { connection.stop() }

        clock.advance(by: .seconds(21))
        try await pollWatchdog(clock)
        try await waitFor { socket.pings == 1 }
        socket.arrive(at: clock.timing.now())
        // Relative, not cumulative: the loop has to actually see the
        // activity before the socket goes quiet again.
        try await pollWatchdog(clock)
        clock.advance(by: .seconds(21))
        try await pollWatchdog(clock)
        try await waitFor { socket.pings == 2 }
        #expect(socket.goingAwayCancels == 0)
    }

    // MARK: - The marks themselves (#111 P2)

    // 20 s to the ping, read at a 5 s poll: a socket idle for 19 s is left
    // alone, and one idle for 20 is challenged by 25. The numbers are the
    // contract's, so a policy that drifts back to 30/45 fails here.
    @Test
    func aSocketIsPingedOnceItHasBeenIdleForTwentySecondsAndNotBefore() async throws {
        let clock = ManualTerminalClock()
        let socket = WatchdogSocket(lastActivity: clock.timing.now())
        let connection = try eventsLink(socket, clock)
        defer { connection.stop() }

        clock.advance(by: .seconds(19))
        try await pollWatchdog(clock)
        #expect(socket.pings == 0)

        clock.advance(by: .seconds(2))
        try await pollWatchdog(clock)
        try await waitFor { socket.pings == 1 }
        #expect(socket.goingAwayCancels == 0)
    }

    // 35 s to the cycle, on the same 5 s poll: silent for 34 s is still a
    // socket, silent for 35 is cut by 40.
    @Test
    func aSocketIsCycledOnceItHasBeenSilentForThirtyFiveSecondsAndNotBefore() async throws {
        let clock = ManualTerminalClock()
        let socket = WatchdogSocket(lastActivity: clock.timing.now())
        let connection = try eventsLink(socket, clock)
        defer { connection.stop() }

        clock.advance(by: .seconds(34))
        try await pollWatchdog(clock)
        #expect(socket.goingAwayCancels == 0)

        clock.advance(by: .seconds(2))
        try await releaseWatchdogPoll(clock)
        try await waitFor { socket.goingAwayCancels == 1 }
    }

    // MARK: - What the log is told (#111)

    // The watchdog's cancel arrives in the receive loop as an ordinary
    // cancelled socket, a beat later: the cause has to be written by the
    // watchdog itself, and the ending must not be counted as a second cycle.
    @Test
    func aWatchdogCycleIsRecordedAsItsOwnCauseAndNotTwice() async throws {
        let clock = ManualTerminalClock()
        let socket = WatchdogSocket(lastActivity: clock.timing.now())
        let recovery = RecoveryLog(pathObserver: ScriptedPathObserver())
        let connection = try eventsLink(socket, clock, recovery: recovery)
        defer { connection.stop() }

        clock.advance(by: .seconds(36))
        try await releaseWatchdogPoll(clock)
        try await waitFor { socket.goingAwayCancels >= 1 }

        let cycles = recovery.ring.filter { $0.source == .events && $0.kind == .cycling }
        #expect(cycles.count == 1)
        #expect(cycles.first?.reason == .watchdog)
        #expect(recovery.counters[.events]?.cycles[.watchdog] == 1)
    }
}
