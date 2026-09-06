import Foundation
@testable import Tavi
import Testing

// The events stream's watchdog (#86, #107), through the real HostConnection
// with a socket whose idle clock and ping the test owns. Only the poll
// interval is shortened; the idle marks are the production ones and are
// crossed through the socket's own `lastActivity`.
@MainActor
struct HostEventsWatchdogTests {
    private static let policy = HostWatchdogPolicy(
        pollInterval: .milliseconds(5),
        pingAfterIdle: 30,
        cycleAfterIdle: 45
    )

    private func link(_ socket: WatchdogSocket) throws -> HostConnection {
        let connection = HostConnection(
            transport: StubHost(.silence).transport,
            makeSocket: { _ in socket },
            watchdogPolicy: Self.policy
        )
        connection.configure(host: try Fixtures.hostEndpoint(), credential: "secret") { _ in }
        return connection
    }

    // The reproduced defect: awaiting the ping inline stopped the loop
    // reaching its own cycle check, so a socket 51 s idle had been pinged
    // once and cancelled never. The ping is owned, not awaited.
    @Test
    func aPingThatNeverReturnsDoesNotStopTheWatchdogCyclingAtItsDeadline() async throws {
        let socket = WatchdogSocket(idle: 31, pingSuspends: true)
        let connection = try link(socket)
        defer {
            connection.stop()
            socket.releasePings()
        }

        try await waitUntil { socket.pings == 1 }
        #expect(socket.goingAwayCancels == 0)

        socket.setIdle(46)
        try await waitUntil { socket.goingAwayCancels >= 1 }
        #expect(socket.pings == 1)
    }

    // A challenge that ignores cancellation stays this link's until it
    // finishes. Activity must not orphan it and let the next quiet period
    // start another (#107).
    @Test
    func aPingThatIgnoresCancellationIsNeverMultipliedByActivity() async throws {
        let socket = WatchdogSocket(idle: 31, pingSuspends: true)
        let connection = try link(socket)
        defer {
            connection.stop()
            socket.releasePings()
        }

        try await waitUntil { socket.pings == 1 }
        for _ in 0..<3 {
            socket.setIdle(0)
            try await socket.waitForPolls(3)
            socket.setIdle(31)
            try await socket.waitForPolls(3)
        }
        #expect(socket.pings == 1)

        // And teardown still cycles the socket, which is what releases the
        // real connection's send.
        socket.setIdle(46)
        try await waitUntil { socket.goingAwayCancels >= 1 }
        #expect(socket.pings == 1)
    }

    // A socket that keeps answering is never pinged and never cycled.
    @Test
    func aSocketThatKeepsAnsweringIsLeftAlone() async throws {
        let socket = WatchdogSocket(idle: 0)
        let connection = try link(socket)
        defer { connection.stop() }

        try await socket.waitForPolls(20)
        #expect(socket.pings == 0)
        #expect(socket.goingAwayCancels == 0)
    }

    // A challenge that completes releases the slot, so the next quiet
    // period is challenged too.
    @Test
    func aSocketThatGoesQuietTwiceIsChallengedTwice() async throws {
        let socket = WatchdogSocket(idle: 31)
        let connection = try link(socket)
        defer { connection.stop() }

        try await waitUntil { socket.pings == 1 }
        socket.setIdle(0)
        // Relative, not cumulative: the loop has to actually see the
        // activity before the socket goes quiet again.
        try await socket.waitForPolls(3)
        socket.setIdle(31)
        try await waitUntil { socket.pings == 2 }
        #expect(socket.goingAwayCancels == 0)
    }
}

// An events socket whose idle clock the test writes and whose ping can hang
// for good. The lock is the whole invariant: written from the test, read
// from the watchdog's task.
final class WatchdogSocket: HostEventsSocketing, @unchecked Sendable {
    private let lock = NSLock()
    private let pingSuspends: Bool
    private var idleSeconds: TimeInterval
    private var pingCount = 0
    private var pollCount = 0
    private var goingAwayCount = 0
    private var pingGates: [CheckedContinuation<Void, Never>] = []

    init(idle: TimeInterval, pingSuspends: Bool = false) {
        idleSeconds = idle
        self.pingSuspends = pingSuspends
    }

    var pings: Int { lock.withLock { pingCount } }
    var goingAwayCancels: Int { lock.withLock { goingAwayCount } }

    func setIdle(_ seconds: TimeInterval) {
        lock.withLock { idleSeconds = seconds }
    }

    // Waits for the watchdog to look at this socket `count` more times than
    // it already has, so a test can say "the loop has seen the change".
    @MainActor
    func waitForPolls(_ count: Int) async throws {
        let mark = lock.withLock { pollCount }
        try await waitUntil { self.lock.withLock { self.pollCount } >= mark + count }
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

    var lastActivity: Date {
        lock.withLock {
            pollCount += 1
            return Date().addingTimeInterval(-idleSeconds)
        }
    }

    func resume() {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await Task.sleep(for: .seconds(3_600))
        throw CancellationError()
    }

    func ping() async throws {
        lock.withLock { pingCount += 1 }
        guard pingSuspends else { return }
        await withCheckedContinuation { continuation in
            lock.withLock { pingGates.append(continuation) }
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard closeCode == .goingAway else { return }
        lock.withLock { goingAwayCount += 1 }
    }
}
