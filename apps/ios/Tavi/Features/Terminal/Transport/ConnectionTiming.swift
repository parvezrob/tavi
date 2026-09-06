import Foundation

// The one time domain the connection code runs on: its timer and its clock,
// so a test can age a connection rather than wait it out. Shared by the
// terminal and the events stream (#111).
struct ConnectionTiming: Sendable {
    let sleep: @Sendable (Duration) async throws -> Void
    let now: @Sendable () -> ContinuousClock.Instant

    init(
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) {
        self.sleep = sleep
        self.now = now
    }

    static let live = ConnectionTiming { duration in
        try await Task.sleep(for: duration)
    }
}
