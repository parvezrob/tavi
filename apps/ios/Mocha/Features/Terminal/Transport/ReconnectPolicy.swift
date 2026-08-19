import Foundation

struct ReconnectPolicy: Sendable, Equatable {
    let initialDelay: Duration
    let maximumDelay: Duration
    let multiplier: Int

    static let terminalDefault = ReconnectPolicy(
        initialDelay: .milliseconds(500),
        maximumDelay: .seconds(8),
        multiplier: 2
    )

    init(initialDelay: Duration, maximumDelay: Duration, multiplier: Int) {
        precondition(initialDelay > .zero)
        precondition(maximumDelay >= initialDelay)
        precondition(multiplier >= 1)
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.multiplier = multiplier
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
