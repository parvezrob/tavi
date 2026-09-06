import Foundation

struct HeartbeatPolicy: Sendable, Equatable {
    let interval: Duration
    // How long the host has to answer a ping that is on the wire.
    let timeout: Duration
    // How long the outbound queue has to put that ping on the wire: a queue
    // that never drains is as dead as a silent host (#107).
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

// The two round trips the terminal reports: dial to first output, and the
// last keystroke to the output that answered it.
struct TerminalLatencyMetrics {
    private(set) var firstPaintMilliseconds: Double?
    private(set) var inputToOutputMilliseconds: Double?
    private(set) var connectionStartedAt: ContinuousClock.Instant?
    private var inputSentAt: ContinuousClock.Instant?

    mutating func reset() {
        firstPaintMilliseconds = nil
        inputToOutputMilliseconds = nil
    }

    mutating func connectionStarted(at now: ContinuousClock.Instant) {
        connectionStartedAt = now
    }

    mutating func inputSent(at now: ContinuousClock.Instant) {
        inputSentAt = now
    }

    // Input that did not reach the host answers nothing.
    mutating func inputAbandoned() {
        inputSentAt = nil
    }

    mutating func outputArrived(at now: ContinuousClock.Instant) {
        if firstPaintMilliseconds == nil, let connectionStartedAt {
            firstPaintMilliseconds = connectionStartedAt.milliseconds(to: now)
        }
        if let inputSentAt {
            inputToOutputMilliseconds = inputSentAt.milliseconds(to: now)
            self.inputSentAt = nil
        }
    }
}
