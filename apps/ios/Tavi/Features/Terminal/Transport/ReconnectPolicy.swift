import Foundation

struct ReconnectPolicy: Sendable, Equatable {
    // The TCP connection budget the terminal puts on its own URLRequest;
    // NetworkWebSocketTask maps it to NWProtocolTCP.Options.connectionTimeout
    // and nothing else, so it bounds establishing the socket, not TLS, the
    // upgrade, or the wait for ready. `connectDeadline` must stay above it:
    // a path that never connects is reported by the transport with its own
    // reason, and everything after that is the controller's to bound (#107).
    static let terminalTCPConnectionTimeout: TimeInterval = 10

    let initialDelay: Duration
    let maximumDelay: Duration
    let multiplier: Int
    // An attempt that produces no ready message within this window is
    // cycled instead of hanging on a dead path.
    let connectDeadline: Duration
    // How long a connection must stay ready before the backoff forgets the
    // attempts behind it. A link that works for one message and dies stays
    // on the slow end of the schedule, as the events stream already does.
    let sustainedHealthInterval: Duration

    static let terminalDefault = ReconnectPolicy(
        initialDelay: .milliseconds(250),
        maximumDelay: .seconds(8),
        multiplier: 2,
        // Twelve, not three: the host looks the agent up in herdr before it
        // upgrades the socket, so a reachable computer can take four
        // seconds to say ready, and three cut every attempt off (#107). The
        // bound stays finite and sits two seconds above the TCP budget, so
        // it is the one thing bounding a socket that connects and then
        // stalls in TLS, in the upgrade, or before ready.
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
