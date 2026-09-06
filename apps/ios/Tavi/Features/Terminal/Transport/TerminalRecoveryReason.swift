import Foundation

// Why a terminal connection was cycled, as a stable identifier the logs can
// be read by (#107). Diagnostics only, and deliberately closed: a reason
// code, a generation number, an attempt count and a duration are the whole
// vocabulary — no URLs, credentials, host error text, prompts or terminal
// output ever join them.
enum TerminalRecoveryReason: String, Sendable {
    case connectDeadline = "connect-deadline"
    case heartbeatPongMissing = "heartbeat-pong-missing"
    case heartbeatSendStalled = "heartbeat-send-stalled"
    case networkPathLost = "network-path-lost"
    case outboundFailed = "outbound-failed"
    case transportDisconnected = "transport-disconnected"
    case transportFailed = "transport-failed"
}
