import Foundation

// Why a terminal connection was cycled, as a fixed token the logs can be
// read by (#107). Deliberately closed: no URLs, credentials, host error
// text or terminal output ever join it.
enum TerminalRecoveryReason: String, Sendable {
    case connectDeadline = "connect-deadline"
    case heartbeatPongMissing = "heartbeat-pong-missing"
    case heartbeatSendStalled = "heartbeat-send-stalled"
    case networkPathLost = "network-path-lost"
    case outboundFailed = "outbound-failed"
    case outputDiscarded = "output-discarded"
    case transportDisconnected = "transport-disconnected"
    case transportFailed = "transport-failed"
}
