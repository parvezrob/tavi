import Foundation
@testable import Tavi
import Testing

// The events link's retry delay through the real HostConnection (#111): who
// ends it, what that costs the backoff, and what a wake meant for one dial
// may never do to the next.
@MainActor
struct HostConnectionRetryWakeTests {
    // Two attempts far enough apart to tell by their length, and nowhere
    // near the link's other waits (the 5 s connect deadline, the 30 s
    // latency poll, the 1.5 s between two probes).
    private static let schedule = ReconnectPolicy(
        initialDelay: .seconds(1),
        maximumDelay: .seconds(8),
        multiplier: 2,
        connectDeadline: .seconds(60)
    )
    private let firstDelay = Duration.milliseconds(800)...Duration.seconds(1)
    private let secondDelay = Duration.milliseconds(1_600)...Duration.seconds(2)

    private func link(
        _ sockets: HeldEventsSockets,
        _ clock: ManualTerminalClock
    ) throws -> HostConnection {
        let connection = HostConnection(
            transport: StubHost(.silence).transport,
            makeSocket: sockets.make,
            reconnectPolicy: Self.schedule,
            timing: clock.timing
        )
        connection.configure(host: try Fixtures.hostEndpoint(), credential: "secret") { _ in }
        return connection
    }

    // A network that comes back is a real signal: dial now. The attempt
    // count stays, so the dial after it is still the second in the schedule.
    @Test func aWakeDuringTheRetryDelayDialsNowAndKeepsTheAttemptCount() async throws {
        let clock = ManualTerminalClock()
        let sockets = HeldEventsSockets(HeldEventsSocket(.drop), HeldEventsSocket(.drop))
        let connection = try link(sockets, clock)
        defer {
            connection.stop()
            sockets.releaseHolds()
        }

        try await waitFor { await clock.hasWaiter(within: self.firstDelay) }
        connection.wakeRetry()
        try await waitFor { sockets.dials == 2 }
        try await waitFor { await clock.hasWaiter(within: self.secondDelay) }
    }

    @Test func aDelayNobodyWakesDialsAgainWhenItElapses() async throws {
        let clock = ManualTerminalClock()
        let sockets = HeldEventsSockets(HeldEventsSocket(.drop))
        let connection = try link(sockets, clock)
        defer {
            connection.stop()
            sockets.releaseHolds()
        }

        try await waitFor { await clock.hasWaiter(within: self.firstDelay) }
        #expect(sockets.dials == 1)
        try await clock.resumeAll(within: firstDelay)
        try await waitFor { sockets.dials == 2 }
    }

    @Test func stoppingDuringTheRetryDelayNeverDialsAgain() async throws {
        let clock = ManualTerminalClock()
        let sockets = HeldEventsSockets(HeldEventsSocket(.drop))
        let connection = try link(sockets, clock)
        defer { sockets.releaseHolds() }

        try await waitFor { await clock.hasWaiter(within: self.firstDelay) }
        connection.stop()
        try await waitFor { await clock.hasWaiter(within: self.firstDelay) == false }
        await drainProbes()
        #expect(sockets.dials == 1)
    }

    // The computer sheet moved to another computer: the wait belonging to
    // the previous one dies with it rather than dialling it once more.
    @Test func reconfiguringDuringTheRetryDelayEndsTheOldWait() async throws {
        let clock = ManualTerminalClock()
        let sockets = HeldEventsSockets(HeldEventsSocket(.drop), HeldEventsSocket(.hold))
        let connection = try link(sockets, clock)
        defer {
            connection.stop()
            sockets.releaseHolds()
        }

        try await waitFor { await clock.hasWaiter(within: self.firstDelay) }
        connection.configure(host: try Fixtures.hostEndpoint(probeLaptop), credential: "other") { _ in }
        try await waitFor { sockets.dials == 2 }
        try await waitFor { await clock.hasWaiter(within: self.firstDelay) == false }
    }

    // The wake can arrive before the dial it belongs to has unwound; the
    // wait that follows that dial honours it. The next drop is a new outage
    // and waits its own delay out.
    @Test func aWakeBeforeTheWaitRegistersSkipsThatDialsDelayOnly() async throws {
        let clock = ManualTerminalClock()
        let sockets = HeldEventsSockets(HeldEventsSocket(.hold, .drop), HeldEventsSocket(.hold, .drop))
        let connection = try link(sockets, clock)
        defer {
            connection.stop()
            sockets.releaseHolds()
        }

        try await waitFor { sockets.dials == 1 }
        connection.wakeRetry()
        sockets.releaseHolds()
        try await waitFor { sockets.dials == 2 }
        #expect(await clock.hasWaiter(within: firstDelay) == false)

        sockets.releaseHolds()
        try await waitFor { await clock.hasWaiter(within: self.secondDelay) }
    }
}
