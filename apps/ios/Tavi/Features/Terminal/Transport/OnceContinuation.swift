import Foundation

// A continuation that can be resumed from two places (the receive
// completion and a state change) and takes only the first.
final class OnceContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Error>?

    func attach(_ continuation: CheckedContinuation<Value?, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(returning value: Value?) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value?, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}
