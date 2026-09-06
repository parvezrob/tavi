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
    private static let policy = HostWatchdogPolicy.live
    private static let schedule = ReconnectPolicy(
        initialDelay: .seconds(2),
        maximumDelay: .seconds(10),
        multiplier: 2,
        connectDeadline: .seconds(60)
    )

    private func link(_ socket: WatchdogSocket, _ clock: ManualTerminalClock) throws -> HostConnection {
        let connection = HostConnection(
            transport: StubHost(.silence).transport,
            makeSocket: { _ in socket },
            watchdogPolicy: Self.policy,
            reconnectPolicy: Self.schedule,
            timing: clock.timing
        )
        connection.configure(host: try Fixtures.hostEndpoint(), credential: "secret") { _ in }
        return connection
    }

    // One turn of the watchdog loop, released and then waited out: the loop
    // has to have read this idle age — and asked for its next poll — before
    // the test moves the clock again.
    private func poll(_ clock: ManualTerminalClock) async throws {
        try await releasePoll(clock)
        try await waitFor { await clock.hasWaiter(for: Self.policy.pollInterval) }
    }

    // The turn that ends the loop asks for no next poll, so the caller waits
    // on what that turn did instead.
    private func releasePoll(_ clock: ManualTerminalClock) async throws {
        try await waitFor { await clock.hasWaiter(for: Self.policy.pollInterval) }
        try await clock.resumeAll(for: Self.policy.pollInterval)
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
}

// An events socket whose every fact the test writes: when a frame last
// arrived, what it carried, and whether a ping ever returns. The lock is the
// whole invariant: written from the test, read from the watchdog's task.
final class WatchdogSocket: HostEventsSocketing, @unchecked Sendable {
    private let lock = NSLock()
    private let pingSuspends: Bool
    private var activity: ContinuousClock.Instant
    private var pingCount = 0
    private var goingAwayCount = 0
    private var pingGates: [CheckedContinuation<Void, Never>] = []
    private var frames: [String] = []
    // A reader is handed a frame, or nil when the socket is cancelled
    // under it.
    private var readers: [CheckedContinuation<String?, Never>] = []

    init(lastActivity: ContinuousClock.Instant, pingSuspends: Bool = false) {
        activity = lastActivity
        self.pingSuspends = pingSuspends
    }

    var pings: Int { lock.withLock { pingCount } }
    var goingAwayCancels: Int { lock.withLock { goingAwayCount } }

    // A frame arrived at this instant and nothing else changed — the socket
    // is answering, and the watchdog's idle age says so.
    func arrive(at instant: ContinuousClock.Instant) {
        lock.withLock { activity = instant }
    }

    // Hands a frame to whichever dial is reading; the arrival is activity,
    // stamped at the instant the test says it landed.
    func deliver(_ text: String, at instant: ContinuousClock.Instant) {
        let reader = lock.withLock { () -> CheckedContinuation<String?, Never>? in
            activity = instant
            guard !readers.isEmpty else {
                frames.append(text)
                return nil
            }
            return readers.removeFirst()
        }
        reader?.resume(returning: text)
    }

    // Resumes every ping the test left hanging — all of them, not just the
    // last: if the "only one challenge" assertion is the thing that failed,
    // the extra continuations must still be released rather than leaked.
    func releasePings() {
        let gates = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { pingGates.removeAll() }
            return pingGates
        }
        gates.forEach { $0.resume() }
    }

    var lastActivity: ContinuousClock.Instant { lock.withLock { activity } }

    func resume() {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        let frame = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                let ready = lock.withLock { () -> String? in
                    guard frames.isEmpty else { return frames.removeFirst() }
                    readers.append(continuation)
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            releaseReaders()
        }
        guard let frame else { throw NetworkWebSocketTask.Failure.cancelled }
        return .string(frame)
    }

    func ping() async throws {
        lock.withLock { pingCount += 1 }
        guard pingSuspends else { return }
        await withCheckedContinuation { continuation in
            lock.withLock { pingGates.append(continuation) }
        }
    }

    // A cancelled socket releases the read it was holding, as a real one
    // does: the dial ends rather than waiting for a host that has gone.
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if closeCode == .goingAway { lock.withLock { goingAwayCount += 1 } }
        releaseReaders()
    }

    private func releaseReaders() {
        let waiting = lock.withLock { () -> [CheckedContinuation<String?, Never>] in
            defer { readers.removeAll() }
            return readers
        }
        waiting.forEach { $0.resume(returning: nil) }
    }
}
