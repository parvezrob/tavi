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

    var canSubmitInput: Bool {
        self == .connected
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
            state == .suspended || state == .ended || state == .waitingForNetwork
                ? state
                : .reconnecting(attempt: max(1, nextAttempt))
        case .networkLost:
            switch state {
            case .connecting, .connected, .reconnecting:
                .waitingForNetwork
            case .idle, .waitingForNetwork, .suspended, .ended, .failed:
                state
            }
        case .suspend:
            state == .ended || state == .failed ? state : .suspended
        case .resume:
            state == .suspended ? .connecting : state
        case .terminalExited:
            .ended
        case .stop:
            .idle
        case .unrecoverableFailure:
            .failed
        }
    }
}
