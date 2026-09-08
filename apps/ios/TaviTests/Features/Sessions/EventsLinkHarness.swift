import Foundation
@testable import Tavi
import Testing

// The events link driven as the app runs it: the real HostConnection, the
// production watchdog policy, a socket whose every fact the test writes, and
// a clock the test moves. Nothing here waits out a real deadline (#107, #111).

// A manual clock tells waits apart by their length alone, so the lengths a
// suite can see have to stay distinct: the watchdog's 5 s poll, the probe's
// 1.5 s gap between two questions, the handover's 2 s budget, the connect
// deadline, the first-frame remainder, and the step of the schedule the link
// is sitting out. `schedule` overlaps the handover budget in its first step
// (1.6–2.0 s of jitter around 2 s), which is why a suite that has a challenge
// outstanding *and* a retry delay to release uses `wideSchedule`, whose first
// step (6.4–8.0 s) collides with nothing.
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
    // A first step clear of the 2 s handover budget and of the 5 s watchdog
    // poll, for the tests that have to tell a dead dial's deadline from the
    // delay before its replacement.
    static let wideSchedule = ReconnectPolicy(
        initialDelay: .seconds(8),
        maximumDelay: .seconds(10),
        multiplier: 2,
        connectDeadline: .seconds(60)
    )
    static let wideFirstDelay = Duration.milliseconds(6_400)...Duration.seconds(8)
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
        ignoresCancel: Bool = false,
        schedule: ReconnectPolicy = EventsLinkDefaults.schedule,
        host: StubHost = StubHost(.silence)
    ) throws {
        let clock = ManualTerminalClock()
        self.clock = clock
        socket = WatchdogSocket(
            lastActivity: clock.timing.now(),
            pingSuspends: pingSuspends,
            ignoresCancel: ignoresCancel
        )
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
        socket.releaseReceives()
    }
}

// One caveat the scripted path observer carries: its stream has a single
// consumer, and a link that is stopped and started subscribes a second time,
// which receives nothing. A test that restarts a link therefore cannot drive
// it with further `paths.emit` — ask the link for the challenge directly
// (`challengeHandover()`), or the test will pass whatever the code does.
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
        makeSocket: { _ in WatchdogSocketHandle(socket) },
        watchdogPolicy: EventsLinkDefaults.policy,
        reconnectPolicy: schedule,
        timing: clock.timing,
        pathObserver: paths
    )
    connection.configure(host: try Fixtures.hostEndpoint(), credential: "secret", recovery: recovery) { _ in }
    return connection
}

// The one wait in this file that is not on the manual clock, and the only
// one: a probe answer comes back from the stub host's own actor, and yields
// cost no time, so `waitFor`'s budget of them can be spent before that
// executor has run at all. Everything the link is timed by — the retry delay,
// the watchdog poll, the challenge budget, the first-frame arm — is still
// crossed by moving `ConnectionTiming`, never by waiting.
@MainActor
func waitForProbe(_ condition: () async -> Bool) async throws {
    // Generous, because it exits the moment the condition holds and the
    // suites around it are yielding hard at the same main actor.
    for _ in 0..<4_000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw TerminalTestFailure()
}

// The retry delay a dial is sitting out: waited for by its own length, then
// released. The window belongs to one step of one schedule, so what it
// matches is never another bound.
@MainActor
func releaseRetryDelay(_ scene: EventsScene, _ window: ClosedRange<Duration>) async throws {
    try await waitFor { await scene.clock.hasWaiter(within: window) }
    try await scene.clock.resumeAll(within: window)
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

// A real link opens a new socket for every dial, and the link's own "is this
// still mine?" checks depend on it: a superseded dial holds an object the
// replacement never uses, so the dial that unwinds last cannot clear the live
// dial's slot or cancel its challenge. One double handed to every dial broke
// that — the identity check matched, and a dial unwinding after its
// replacement had started (which is what a loaded machine makes likely) took
// the replacement's socket away with it. Each dial therefore gets its own
// handle onto the one set of facts the test reads and writes (#111).
final class WatchdogSocketHandle: HostEventsSocketing, Sendable {
    private let socket: WatchdogSocket

    init(_ socket: WatchdogSocket) {
        self.socket = socket
    }

    var lastActivity: ContinuousClock.Instant { socket.lastActivity }
    var lastFrameAt: ContinuousClock.Instant { socket.lastFrameAt }

    func resume() {
        socket.resume()
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await socket.receive()
    }

    func ping(payload: Data) async throws {
        try await socket.ping(payload: payload)
    }

    func onPong(_ handler: @escaping @Sendable (Data) -> Void) {
        socket.onPong(handler)
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        socket.cancel(with: closeCode, reason: reason)
    }
}

// An events socket whose every fact the test writes: when a frame last
// arrived, what it carried, whether a ping ever returns, and what comes back
// as its pong. The lock is the whole invariant: written from the test, read
// from the link's tasks.
final class WatchdogSocket: HostEventsSocketing, @unchecked Sendable {
    private let lock = NSLock()
    private let pingSuspends: Bool
    // A socket that does not let go of its reader when it is cancelled: the
    // dial reading it is still unwinding when the next one starts, which is
    // the ordering a defer's `self.socket === socket` guard fails on (#108).
    private let ignoresCancel: Bool
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

    init(lastActivity: ContinuousClock.Instant, pingSuspends: Bool = false, ignoresCancel: Bool = false) {
        activity = lastActivity
        frameActivity = lastActivity
        self.pingSuspends = pingSuspends
        self.ignoresCancel = ignoresCancel
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
    //
    // `.normalClosure` is the exception, and it is what one double serving
    // every dial costs: it is a dial's polite close of a socket it has
    // already stopped reading, and a real link would be closing an object the
    // next dial never sees. Carrying it over here would shut the replacement
    // before its first read — every path that actually ends a read (`stop()`,
    // a cycle, `failReceive`) goes through `.goingAway` or the test instead.
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard closeCode != .normalClosure else { return }
        lock.withLock {
            isCancelled = true
            if closeCode == .goingAway { goingAwayCount += 1 }
        }
        guard !ignoresCancel else { return }
        releaseReaders()
    }

    // Lets go of every parked read, so teardown leaves nothing behind.
    func releaseReceives() {
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
