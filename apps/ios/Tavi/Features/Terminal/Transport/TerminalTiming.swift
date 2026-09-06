import Foundation

struct HeartbeatPolicy: Sendable, Equatable {
    let interval: Duration
    // How long the host has to answer a ping that is already on the wire.
    let timeout: Duration
    // How long the outbound queue has to put that ping on the wire. Its own
    // bound, because a queue that never drains is as dead as a silent host
    // and the host's answer budget must not be spent waiting for our own
    // send to complete (#107).
    let sendTimeout: Duration

    static let terminalDefault = HeartbeatPolicy(
        interval: .seconds(10),
        timeout: .seconds(5)
    )

    init(
        interval: Duration,
        timeout: Duration,
        sendTimeout: Duration = .seconds(5)
    ) {
        self.interval = interval
        self.timeout = timeout
        self.sendTimeout = sendTimeout
    }
}

extension Duration {
    // Whole milliseconds, for the recovery diagnostics.
    var wholeMilliseconds: Int {
        let parts = components
        return Int(parts.seconds) * 1_000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
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
    // The controller's clock as well as its timer: how long a connection
    // has held decides whether the backoff forgets it, and a test must be
    // able to put that age where it needs it rather than wait it out.
    let now: @Sendable () -> ContinuousClock.Instant

    init(
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) {
        self.sleep = sleep
        self.now = now
    }

    static let live = TerminalTiming { duration in
        try await Task.sleep(for: duration)
    }
}
