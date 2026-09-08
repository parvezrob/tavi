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
    private func link(_ socket: WatchdogSocket, _ clock: ManualTerminalClock, recovery: RecoveryLog? = nil) throws -> HostConnection {
        try eventsLink(socket, clock, recovery: recovery)
    }

    private func poll(_ clock: ManualTerminalClock) async throws {
        try await pollWatchdog(clock)
    }

    private func releasePoll(_ clock: ManualTerminalClock) async throws {
        try await releaseWatchdogPoll(clock)
    }

    // The reproduced defect: awaiting the ping inline stopped the loop
    // reaching its own cycle check, so a socket 51 s idle had been pinged
    // once and cancelled never. The ping is owned, not awaited.
    @Test
    func aPingThatNeverReturnsDoesNotStopTheWatchdogCyclingAtItsDeadline() async throws {
        let clock = ManualTerminalClock()
        let socket = WatchdogSocket(lastActivity: clock.timing.now(), pingSuspends: true)
        let connection = try link(socket, clock)
        defer {
            connection.stop()
            socket.releasePings()
        }

        clock.advance(by: .seconds(31))
        try await poll(clock)
        try await waitFor { socket.pings == 1 }
        #expect(socket.goingAwayCancels == 0)

        clock.advance(by: .seconds(15))
        try await releasePoll(clock)
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
        let connection = try link(socket, clock)
        defer {
            connection.stop()
            socket.releasePings()
        }

        clock.advance(by: .seconds(31))
        try await poll(clock)
        try await waitFor { socket.pings == 1 }
        for _ in 0..<3 {
            socket.arrive(at: clock.timing.now())
            try await poll(clock)
            clock.advance(by: .seconds(31))
            try await poll(clock)
        }
        #expect(socket.pings == 1)

        // And teardown still cycles the socket, which is what releases the
        // real connection's send.
        clock.advance(by: .seconds(15))
        try await releasePoll(clock)
        try await waitFor { socket.goingAwayCancels >= 1 }
        #expect(socket.pings == 1)
    }

    // A socket that keeps answering is never pinged and never cycled.
    @Test
    func aSocketThatKeepsAnsweringIsLeftAlone() async throws {
        let clock = ManualTerminalClock()
        let socket = WatchdogSocket(lastActivity: clock.timing.now())
        let connection = try link(socket, clock)
        defer { connection.stop() }

        for _ in 0..<20 {
            clock.advance(by: .seconds(5))
            socket.deliver(Fixtures.agentsFrame(), at: clock.timing.now())
            try await poll(clock)
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
        let connection = try link(socket, clock)
        defer { connection.stop() }

        clock.advance(by: .seconds(31))
        try await poll(clock)
        try await waitFor { socket.pings == 1 }
        socket.arrive(at: clock.timing.now())
        // Relative, not cumulative: the loop has to actually see the
        // activity before the socket goes quiet again.
        try await poll(clock)
        clock.advance(by: .seconds(31))
        try await poll(clock)
        try await waitFor { socket.pings == 2 }
        #expect(socket.goingAwayCancels == 0)
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
        let connection = try link(socket, clock, recovery: recovery)
        defer { connection.stop() }

        clock.advance(by: .seconds(46))
        try await releasePoll(clock)
        try await waitFor { socket.goingAwayCancels >= 1 }

        let cycles = recovery.ring.filter { $0.source == .events && $0.kind == .cycling }
        #expect(cycles.count == 1)
        #expect(cycles.first?.reason == .watchdog)
        #expect(recovery.counters[.events]?.cycles[.watchdog] == 1)
    }
}
