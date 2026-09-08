import Foundation
@testable import Tavi
import Testing

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

    nonisolated var timing: ConnectionTiming {
        ConnectionTiming(
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
    private let subscriptions = Subscriptions()

    // How many times a caller asked for the updates: one stream is handed
    // out, so only the count proves a second monitor was never started.
    var subscriptionCount: Int { subscriptions.count }

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func updates() -> AsyncStream<NetworkPathSnapshot> {
        subscriptions.record()
        return stream
    }

    func emit(_ snapshot: NetworkPathSnapshot) {
        continuation.yield(snapshot)
    }
}

// The lock is the whole invariant: written from the watch's task, read from
// the test.
private final class Subscriptions: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func record() {
        lock.withLock { value += 1 }
    }
}
