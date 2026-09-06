import Foundation

enum TerminalConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case waitingForNetwork
    case suspended
    case ended
    case failed
    // Another connection owns this terminal (#108). Final: nothing retries,
    // and the agent behind it is still running.
    case superseded

    var canSubmitInput: Bool {
        self == .connected
    }

    // A conclusion rather than a condition to report: nothing retries out of
    // these, and the last screen stays readable.
    var isFinal: Bool {
        switch self {
        case .ended, .failed, .superseded:
            true
        case .idle, .connecting, .connected, .reconnecting, .waitingForNetwork, .suspended:
            false
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .idle:
            "Not connected"
        case .connecting:
            "Connecting"
        case .connected:
            "Connected"
        case let .reconnecting(attempt):
            "Reconnecting, attempt \(attempt)"
        case .waitingForNetwork:
            "Waiting for a network connection"
        case .suspended:
            "Paused in background"
        case .ended:
            "Terminal ended"
        case .failed:
            "Connection failed"
        case .superseded:
            "Another connection took over this terminal"
        }
    }
}

enum TerminalConnectionAction: Sendable, Equatable {
    case connect
    case ready
    case connectionLost(nextAttempt: Int)
    case networkLost
    case suspend
    case resume
    case terminalExited
    case stop
    case takenOver
    case unrecoverableFailure
}

enum TerminalConnectionReducer {
    static func reduce(
        _ state: TerminalConnectionState,
        action: TerminalConnectionAction
    ) -> TerminalConnectionState {
        switch action {
        case .connect:
            .connecting
        case .ready:
            .connected
        case let .connectionLost(nextAttempt):
            // While the network path is down, "reconnecting attempt N" would
            // be dishonest — no attempt can succeed until the path returns.
            state == .suspended || state == .ended || state == .waitingForNetwork || state == .superseded
                ? state
                : .reconnecting(attempt: max(1, nextAttempt))
        case .networkLost:
            switch state {
            case .connecting, .connected, .reconnecting:
                .waitingForNetwork
            case .idle, .waitingForNetwork, .suspended, .ended, .failed, .superseded:
                state
            }
        case .suspend:
            // A superseded session must never become suspended: the next
            // foreground would redial a terminal this client lost (#108).
            state.isFinal ? state : .suspended
        case .resume:
            state == .suspended ? .connecting : state
        case .terminalExited:
            .ended
        case .stop:
            .idle
        case .takenOver:
            state == .ended || state == .failed ? state : .superseded
        case .unrecoverableFailure:
            .failed
        }
    }
}
