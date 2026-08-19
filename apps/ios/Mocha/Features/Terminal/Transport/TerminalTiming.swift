import Foundation

struct HeartbeatPolicy: Sendable, Equatable {
    let interval: Duration
    let timeout: Duration

    static let terminalDefault = HeartbeatPolicy(
        interval: .seconds(15),
        timeout: .seconds(10)
    )
}

struct TerminalTiming: Sendable {
    let sleep: @Sendable (Duration) async throws -> Void

    static let live = TerminalTiming { duration in
        try await Task.sleep(for: duration)
    }
}
