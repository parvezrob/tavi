import Foundation
@testable import Tavi
import Testing

// The events link driven as the app runs it: the real HostConnection, the
// production watchdog policy, a socket whose every fact the test writes, and
// a clock the test moves. Nothing here waits out a real deadline (#107, #111).

enum EventsLinkDefaults {
    static let policy = HostWatchdogPolicy.live
    // Long enough that the one wait this harness releases by its length is
    // the watchdog's poll and never the link's connect deadline.
    static let schedule = ReconnectPolicy(
        initialDelay: .seconds(2),
        maximumDelay: .seconds(10),
        multiplier: 2,
        connectDeadline: .seconds(60)
    )
    // The production connect deadline, for the suites that are about what
    // the deadline task does rather than about the socket under it.
    static let probing = ReconnectPolicy(
        initialDelay: .seconds(2),
        maximumDelay: .seconds(10),
        multiplier: 2,
        connectDeadline: .seconds(5)
    )
    // The schedule's first three steps, less up to 20 % of jitter: which one
    // the link is sitting out is how a test reads its attempt count.
    static let firstDelay = Duration.milliseconds(1_600)...Duration.seconds(2)
    static let secondDelay = Duration.milliseconds(3_200)...Duration.seconds(4)
    static let thirdDelay = Duration.milliseconds(6_400)...Duration.seconds(8)
}

// A link with everything a P2 test needs around it: the clock, the socket,
// the path the phone is on, and the log to read the verdicts out of.
@MainActor
final class EventsScene {
    static let wifi = NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "en0")
    static let cellular = NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "pdp_ip0")
    static let otherWiFi = NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "en1")
    static let noPath = NetworkPathSnapshot(isSatisfied: false, interfaceIdentity: "none")

    let clock: ManualTerminalClock
    let socket: WatchdogSocket
    let paths = ScriptedPathObserver()
    let recovery: RecoveryLog
    let link: HostConnection

    // The log gets its own observer: one scripted stream has one consumer,
    // and the log's diagnostic stamp must not eat the link's path events.
    init(
        pingSuspends: Bool = false,
        schedule: ReconnectPolicy = EventsLinkDefaults.schedule,
        host: StubHost = StubHost(.silence)
    ) throws {
        let clock = ManualTerminalClock()
        self.clock = clock
        socket = WatchdogSocket(lastActivity: clock.timing.now(), pingSuspends: pingSuspends)
        recovery = RecoveryLog(timing: clock.timing, pathObserver: ScriptedPathObserver())
        link = try eventsLink(socket, clock, recovery: recovery, schedule: schedule, paths: paths, host: host)
    }

    var now: ContinuousClock.Instant { clock.timing.now() }

    // What a handover check needs before it can happen: a dial that has
    // delivered a frame, and a path baseline, so the next snapshot is a
    // change and not a first sighting.
    func establish() async throws {
        socket.deliver(Fixtures.agentsFrame(), at: now)
        try await waitFor { self.link.hasLoaded }
        paths.emit(Self.wifi)
        await settle()
    }

    func moveTo(_ snapshot: NetworkPathSnapshot) async {
        paths.emit(snapshot)
        await settle()
    }

    // What the log was told about the events link, in order.
    func events(_ kind: RecoveryLog.Kind) -> [RecoveryEvent] {
        recovery.ring.filter { $0.source == .events && $0.kind == kind }
    }

    func tearDown() {
        link.stop()
        socket.releasePings()
    }
}

@MainActor
func eventsLink(
    _ socket: WatchdogSocket,
    _ clock: ManualTerminalClock,
    recovery: RecoveryLog? = nil,
    schedule: ReconnectPolicy = EventsLinkDefaults.schedule,
    paths: ScriptedPathObserver = ScriptedPathObserver(),
    host: StubHost = StubHost(.silence)
) throws -> HostConnection {
    let connection = HostConnection(
        transport: host.transport,
        makeSocket: { _ in socket },
        watchdogPolicy: EventsLinkDefaults.policy,
        reconnectPolicy: schedule,
        timing: clock.timing,
        pathObserver: paths
    )
    connection.configure(host: try Fixtures.hostEndpoint(), credential: "secret", recovery: recovery) { _ in }
    return connection
}

// Some of what these suites wait for crosses an actor hop to the stub host
// and back — a probe answer, the verdict behind it — and yielding alone does
// not always give that time. The condition is still the fact under test; only
// the waiting is by the clock on the wall.
@MainActor
func waitForAnswer(_ condition: () async -> Bool) async throws {
    for _ in 0..<600 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw TerminalTestFailure()
}

// One turn of the watchdog loop, released and then waited out: the loop has
// to have read this idle age — and asked for its next poll — before the test
// moves the clock again.
@MainActor
func pollWatchdog(_ clock: ManualTerminalClock) async throws {
    try await releaseWatchdogPoll(clock)
    try await waitFor { await clock.hasWaiter(for: EventsLinkDefaults.policy.pollInterval) }
}

// The turn that ends the loop asks for no next poll, so the caller waits on
// what that turn did instead.
@MainActor
func releaseWatchdogPoll(_ clock: ManualTerminalClock) async throws {
    try await waitFor { await clock.hasWaiter(for: EventsLinkDefaults.policy.pollInterval) }
    try await clock.resumeAll(for: EventsLinkDefaults.policy.pollInterval)
}

// An events socket whose every fact the test writes: when a frame last
// arrived, what it carried, whether a ping ever returns, and what comes back
// as its pong. The lock is the whole invariant: written from the test, read
// from the link's tasks.
final class WatchdogSocket: HostEventsSocketing, @unchecked Sendable {
    private let lock = NSLock()
    private let pingSuspends: Bool
    private var activity: ContinuousClock.Instant
    private var frameActivity: ContinuousClock.Instant
    private var pingPayloads: [Data] = []
    private var goingAwayCount = 0
    private var pingGates: [CheckedContinuation<Void, Never>] = []
    private var frames: [String] = []
    // A reader is handed a frame, or nil when the socket is cancelled
    // under it.
    private var readers: [CheckedContinuation<String?, Never>] = []
    private var isCancelled = false
    private var resumeCount = 0
    private var pongHandler: (@Sendable (Data) -> Void)?

    init(lastActivity: ContinuousClock.Instant, pingSuspends: Bool = false) {
        activity = lastActivity
        frameActivity = lastActivity
        self.pingSuspends = pingSuspends
    }

    var pings: Int { lock.withLock { pingPayloads.count } }
    // One per dial: the link resumes each socket it opens, so on a socket
    // handed to every dial this is how many dials there have been.
    var resumes: Int { lock.withLock { resumeCount } }
    var goingAwayCancels: Int { lock.withLock { goingAwayCount } }
    // What each challenge carried, in order: a test answers one of them, or
    // deliberately answers with bytes nobody sent.
    var challenges: [Data] { lock.withLock { pingPayloads } }

    // A frame arrived at this instant and nothing else changed — the socket
    // is answering, and both of the watchdog's clocks say so.
    func arrive(at instant: ContinuousClock.Instant) {
        lock.withLock {
            activity = instant
            frameActivity = instant
        }
    }

    // Hands a frame to whichever dial is reading; the arrival is activity,
    // stamped at the instant the test says it landed.
    func deliver(_ text: String, at instant: ContinuousClock.Instant) {
        let reader = lock.withLock { () -> CheckedContinuation<String?, Never>? in
            activity = instant
            frameActivity = instant
            guard !readers.isEmpty else {
                frames.append(text)
                return nil
            }
            return readers.removeFirst()
        }
        reader?.resume(returning: text)
    }

    // The pong for a challenge the test picks, delivered as the transport
    // delivers one: a frame arrived, and its payload reaches the link.
    func answer(_ payload: Data, at instant: ContinuousClock.Instant) {
        let handler = lock.withLock { () -> (@Sendable (Data) -> Void)? in
            activity = instant
            frameActivity = instant
            return pongHandler
        }
        handler?(payload)
    }

    // The reading side fails, as a broken connection does: `lastActivity`
    // moves (the completion arrived) but no frame was ever delivered.
    func failReceive(at instant: ContinuousClock.Instant) {
        let waiting = lock.withLock { () -> [CheckedContinuation<String?, Never>] in
            activity = instant
            isCancelled = true
            defer { readers.removeAll() }
            return readers
        }
        waiting.forEach { $0.resume(returning: nil) }
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
    var lastFrameAt: ContinuousClock.Instant { lock.withLock { frameActivity } }

    // A dial opens the socket it was handed. One double serves every dial,
    // so it is open again here, as a fresh one would be.
    func resume() {
        lock.withLock {
            resumeCount += 1
            isCancelled = false
        }
    }

    func onPong(_ handler: @escaping @Sendable (Data) -> Void) {
        lock.withLock { pongHandler = handler }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        let frame = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                // A reader that registers after the cancel must not wait for
                // a release that has already happened.
                let ready = lock.withLock { () -> String?? in
                    guard !isCancelled else { return .some(nil) }
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

    func ping(payload: Data) async throws {
        lock.withLock { pingPayloads.append(payload) }
        guard pingSuspends else { return }
        await withCheckedContinuation { continuation in
            lock.withLock { pingGates.append(continuation) }
        }
    }

    // A cancelled socket releases the read it was holding, as a real one
    // does: the dial ends rather than waiting for a host that has gone.
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock {
            isCancelled = true
            if closeCode == .goingAway { goingAwayCount += 1 }
        }
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
