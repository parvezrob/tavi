import Foundation

struct HeartbeatPolicy: Sendable, Equatable {
    let interval: Duration
    let timeout: Duration

    static let terminalDefault = HeartbeatPolicy(
        interval: .seconds(10),
        timeout: .seconds(5)
    )
}

struct TerminalTiming: Sendable {
    let sleep: @Sendable (Duration) async throws -> Void

    static let live = TerminalTiming { duration in
        try await Task.sleep(for: duration)
    }
}
