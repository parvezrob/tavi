import Foundation

enum TerminalConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case reconnecting(attempt: Int)
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
            state == .suspended || state == .ended
                ? state
                : .reconnecting(attempt: max(1, nextAttempt))
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
