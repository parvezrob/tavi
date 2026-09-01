import Foundation

struct ReconnectPolicy: Sendable, Equatable {
    let initialDelay: Duration
    let maximumDelay: Duration
    let multiplier: Int
    // An attempt that produces no ready message within this window is
    // cycled instead of hanging on a dead path.
    let connectDeadline: Duration

    static let terminalDefault = ReconnectPolicy(
        initialDelay: .milliseconds(250),
        maximumDelay: .seconds(8),
        multiplier: 2,
        connectDeadline: .seconds(3)
    )

    init(
        initialDelay: Duration,
        maximumDelay: Duration,
        multiplier: Int,
        connectDeadline: Duration = .seconds(3)
    ) {
        precondition(initialDelay > .zero)
        precondition(maximumDelay >= initialDelay)
        precondition(multiplier >= 1)
        precondition(connectDeadline > .zero)
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.multiplier = multiplier
        self.connectDeadline = connectDeadline
    }

    func delay(
        forAttempt attempt: Int,
        jitterPercent: Int = Int.random(in: 80...100)
    ) -> Duration {
        precondition((80...100).contains(jitterPercent))

        var delay = initialDelay
        for _ in 1..<max(1, attempt) {
            let next = delay * multiplier
            delay = min(next, maximumDelay)
            if delay == maximumDelay { break }
        }
        return delay * jitterPercent / 100
    }
}
