import Foundation

struct HeartbeatPolicy: Sendable, Equatable {
    let interval: Duration
    let timeout: Duration

    static let terminalDefault = HeartbeatPolicy(
        interval: .seconds(10),
        timeout: .seconds(5)
    )
}

extension ContinuousClock.Instant {
    // Milliseconds from here to there, for the first-paint and
    // input-to-output measurements.
    func milliseconds(to end: ContinuousClock.Instant) -> Double {
        let components = duration(to: end).components
        let seconds = Double(components.seconds) * 1_000
        let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000
        return seconds + attoseconds
    }
}

struct TerminalTiming: Sendable {
    let sleep: @Sendable (Duration) async throws -> Void

    static let live = TerminalTiming { duration in
        try await Task.sleep(for: duration)
    }
}
