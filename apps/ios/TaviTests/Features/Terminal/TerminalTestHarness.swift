import Foundation
@testable import Tavi
import Testing

// The collaborators the terminal suites drive the real controller with: a
// clock the test moves by hand, a scripted path observer, and a transport
// whose close ordering and send completion the test chooses. Nothing here
// sleeps for a guessed duration.

struct TerminalTestFailure: Error {}

// The budgets the suites below reason about, so a wait and the policy that
// armed it cannot drift apart.
enum TerminalTestDefaults {
    static let host = "https://mac.tailnet.ts.net"
    static let connectDeadline = Duration.seconds(12)
    // One second of retry delay, less up to 20 % of jitter.
    static let retryDelay = Duration.milliseconds(800)...Duration.seconds(1)

    static var reconnectPolicy: ReconnectPolicy {
        ReconnectPolicy(
            initialDelay: .seconds(1),
            maximumDelay: .seconds(1),
            multiplier: 1,
            connectDeadline: connectDeadline,
            sustainedHealthInterval: .seconds(30)
        )
    }
}

@MainActor
func startedController(
    _ transport: RecoveryTransport,
    _ clock: ManualTerminalClock,
    paneID: String = "fixture",
    paths: ScriptedPathObserver = ScriptedPathObserver()
) -> TerminalSessionController {
    let controller = TerminalSessionController(
        client: transport,
        reconnectPolicy: TerminalTestDefaults.reconnectPolicy,
        timing: clock.timing,
        pathObserver: paths
    )
    controller.connect(
        hostText: TerminalTestDefaults.host,
        paneID: paneID,
        credential: "valid-token"
    )
    return controller
}

@MainActor
func waitUntilConnected(
    _ transport: RecoveryTransport,
    _ controller: TerminalSessionController,
    stream: String = "epoch-a"
) async throws {
    try await waitUntilListening(transport, after: 0)
    await transport.emit(.message(.ready(stream: stream, offset: 0, resumed: false)))
    try await waitFor { controller.connectionState == .connected }
}

// `emit` hands the event to the newest waiter, and a cancelled predecessor
// stays parked in `receive()` forever — so a frame emitted before the new
// dial's loop has asked would go to the loop that can no longer act on it.
// Dialling is not enough; the ask is the barrier.
@MainActor
func waitUntilListening(_ transport: RecoveryTransport, after dials: Int) async throws {
    try await waitFor { await transport.connectCount > dials }
    try await waitFor { await transport.receivesSinceConnect >= 1 }
}

// Waits for something the controller reaches on its own tasks.
@MainActor
func waitFor(_ condition: () async -> Bool) async throws {
    for _ in 0..<20_000 {
        if await condition() { return }
        await Task.yield()
    }
    throw TerminalTestFailure()
}

// Lets every task that can already run do so, for the assertions that
// something did *not* happen.
@MainActor
func settle() async {
    for _ in 0..<200 {
        await Task.yield()
    }
}

// Releases the fake's gates and the controller's tasks on both paths. An
// assertion that throws part-way must not leave a live controller and a set
// of suspended continuations behind for the rest of the run.
@MainActor
func withCleanup(
    _ controller: TerminalSessionController,
    _ transport: RecoveryTransport,
    _ body: () async throws -> Void
) async throws {
    do {
        try await body()
    } catch {
        controller.stop()
        await transport.releaseEverything()
        throw error
    }
    controller.stop()
    await transport.releaseEverything()
}

// A terminal transport whose two interesting orderings are the test's to
// pick: whether a superseded receive loop learns of an intentional close
// before or after `disconnect()` returns, and whether a send ever
// completes.
actor RecoveryTransport: TerminalTransporting {
    enum CloseOrdering: Sendable {
        // The superseded loop is handed the close before disconnect()
        // returns — the ordering that wedged the controller (#107).
        case beforeDisconnectReturns
        // disconnect() returns first; the close arrives when the test
        // delivers it.
        case afterDisconnectReturns
    }

    private(set) var connectCount = 0
    private(set) var connectResumes: [TerminalResumePoint?] = []
    // Every ask for the next event, so a test can say "the controller has
    // finished with the frame before this one".
    private(set) var receiveCount = 0
    // Asks belonging to the current dial. An older loop cannot add to it:
    // once the controller has bumped its generation, that loop exits at the
    // top of its own `while` rather than asking again.
    private(set) var receivesSinceConnect = 0
    private(set) var sentMessages: [TerminalClientMessage] = []
    // True while a disconnect is being held open, so a test can let the
    // superseded loop act before it returns.
    private(set) var isGated = false

    private var ordering: CloseOrdering
    private var hangsSends: Bool
    private var connected = false
    private var pendingClose = false
    private var queuedEvents: [TerminalTransportEvent] = []
    private var waiters: [CheckedContinuation<TerminalTransportEvent, Never>] = []
    private var disconnectGate: CheckedContinuation<Void, Never>?
    private var sendGate: [CheckedContinuation<Void, Never>] = []

    init(
        ordering: CloseOrdering = .afterDisconnectReturns,
        hangsSends: Bool = false
    ) {
        self.ordering = ordering
        self.hangsSends = hangsSends
    }

    var latestPingIdentifier: String? {
        sentMessages.reversed().compactMap { message in
            if case let .ping(identifier) = message { return identifier }
            return nil
        }.first
    }

    var inputMessages: [String] {
        sentMessages.compactMap { message in
            if case let .input(value) = message { return value }
            return nil
        }
    }

    func connect(configuration: TerminalConnectionConfiguration, resume: TerminalResumePoint?) throws {
        connectCount += 1
        connectResumes.append(resume)
        receivesSinceConnect = 0
        connected = true
    }

    func receive() async -> TerminalTransportEvent {
        receiveCount += 1
        receivesSinceConnect += 1
        if !queuedEvents.isEmpty { return queuedEvents.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func send(_ message: TerminalClientMessage) async throws {
        sentMessages.append(message)
        guard hangsSends else { return }
        await withCheckedContinuation { sendGate.append($0) }
    }

    func disconnect() async {
        guard connected else { return }
        connected = false
        switch ordering {
        case .beforeDisconnectReturns:
            deliverClose()
            isGated = true
            await withCheckedContinuation { disconnectGate = $0 }
        case .afterDisconnectReturns:
            pendingClose = true
        }
    }

    // The newest waiter is the live receive loop.
    func emit(_ event: TerminalTransportEvent) {
        guard !waiters.isEmpty else {
            queuedEvents.append(event)
            return
        }
        waiters.removeLast().resume(returning: event)
    }

    func deliverPendingClose() {
        guard pendingClose else { return }
        pendingClose = false
        deliverClose()
    }

    func releaseDisconnect() {
        guard let gate = disconnectGate else { return }
        disconnectGate = nil
        isGated = false
        gate.resume()
    }

    func releaseSend() {
        guard !sendGate.isEmpty else { return }
        sendGate.removeFirst().resume()
    }

    // End of test: nothing stays gated, so no continuation is left waiting
    // on a suite that has already finished.
    func releaseEverything() {
        ordering = .afterDisconnectReturns
        hangsSends = false
        releaseDisconnect()
        let sends = sendGate
        sendGate.removeAll()
        sends.forEach { $0.resume() }
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: .disconnected) }
    }

    // The oldest waiter is the superseded receive loop: an intentional close
    // belongs to the socket it was reading. If that loop has already gone,
    // the close belongs to nobody — queuing it would hand a real socket's
    // ending to the dial that replaced it.
    private func deliverClose() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(returning: .disconnected)
    }
}

// Every wait the controller schedules, resumed by the test rather than by
// the passage of time, plus a record of what was ever scheduled — how a
// test says "the answer deadline was never armed".
actor ManualTerminalClock {
    private struct Waiter {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [Waiter] = []
    private var registrations: [Duration: Int] = [:]
    private let instant = ManualInstant()

    nonisolated var timing: TerminalTiming {
        TerminalTiming(
            sleep: { duration in try await self.sleep(for: duration) },
            now: { [instant] in instant.now }
        )
    }

    // Moves what the controller reads as "now" without resuming anything.
    nonisolated func advance(by duration: Duration) {
        instant.advance(by: duration)
    }

    func hasWaiter(for duration: Duration) -> Bool {
        waiters.contains { $0.duration == duration }
    }

    func timesScheduled(_ duration: Duration) -> Int {
        registrations[duration] ?? 0
    }

    // The retry delay carries jitter, so it is matched by the window it
    // falls in rather than by an exact value.
    func hasWaiter(within range: ClosedRange<Duration>) -> Bool {
        waiters.contains { range.contains($0.duration) }
    }

    func resumeAll(within range: ClosedRange<Duration>) throws {
        try resumeAll(matching: { range.contains($0) })
    }

    // Every wait of this length at once: a superseded one is fenced by its
    // own generation and cancellation checks, so resuming it is harmless and
    // the live one is never missed because a cancelled sibling was removed a
    // beat late.
    func resumeAll(for duration: Duration) throws {
        try resumeAll(matching: { $0 == duration })
    }

    private func resumeAll(matching predicate: (Duration) -> Bool) throws {
        let matching = waiters.filter { predicate($0.duration) }
        guard !matching.isEmpty else { throw TerminalTestFailure() }
        waiters.removeAll { predicate($0.duration) }
        matching.forEach { $0.continuation.resume() }
    }

    private func sleep(for duration: Duration) async throws {
        let id = UUID()
        registrations[duration, default: 0] += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, duration: duration, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

// The controller's "now", moved by the test. The lock is the whole
// invariant: written from the test, read from the controller's tasks.
private final class ManualInstant: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock().now
    private var offset: Duration = .zero

    var now: ContinuousClock.Instant {
        lock.withLock { origin.advanced(by: offset) }
    }

    func advance(by duration: Duration) {
        lock.withLock { offset += duration }
    }
}

final class ScriptedPathObserver: NetworkPathObserving {
    private let stream: AsyncStream<NetworkPathSnapshot>
    private let continuation: AsyncStream<NetworkPathSnapshot>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func updates() -> AsyncStream<NetworkPathSnapshot> {
        stream
    }

    func emit(_ snapshot: NetworkPathSnapshot) {
        continuation.yield(snapshot)
    }
}
