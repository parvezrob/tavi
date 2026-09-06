import Foundation

struct ReconnectPolicy: Sendable, Equatable {
    // The terminal's TCP connection budget; NetworkWebSocketTask maps it to
    // the TCP connect timeout and nothing else. `connectDeadline` stays
    // above it and bounds TLS, the upgrade and the wait for ready (#107).
    static let terminalTCPConnectionTimeout: TimeInterval = 10

    let initialDelay: Duration
    let maximumDelay: Duration
    let multiplier: Int
    // An attempt that produces no ready message within this window is
    // cycled instead of hanging on a dead path.
    let connectDeadline: Duration
    // How long a connection must stay ready before the backoff forgets the
    // attempts behind it, as the events stream already does.
    let sustainedHealthInterval: Duration

    static let terminalDefault = ReconnectPolicy(
        initialDelay: .milliseconds(250),
        maximumDelay: .seconds(8),
        multiplier: 2,
        // Twelve, not three: the host looks the agent up in herdr before it
        // upgrades the socket, so a reachable computer can take four seconds
        // to say ready, and three cut every attempt off (#107).
        connectDeadline: .seconds(12)
    )

    init(
        initialDelay: Duration,
        maximumDelay: Duration,
        multiplier: Int,
        connectDeadline: Duration = .seconds(12),
        sustainedHealthInterval: Duration = .seconds(30)
    ) {
        precondition(initialDelay > .zero)
        precondition(maximumDelay >= initialDelay)
        precondition(multiplier >= 1)
        precondition(connectDeadline > .zero)
        precondition(sustainedHealthInterval > .zero)
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.multiplier = multiplier
        self.connectDeadline = connectDeadline
        self.sustainedHealthInterval = sustainedHealthInterval
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
