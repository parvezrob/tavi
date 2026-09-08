import Foundation
@testable import Tavi
import Testing

// The one 2 s handover check, set up the same way for both suites that
// drive it (#111 P2). The four budgets are deliberately different lengths,
// so a test can say which deadline it is resuming and prove which one was
// never armed.
@MainActor
enum HandoverFixture {
    static let interval = Duration.seconds(10)
    static let answerBound = Duration.seconds(5)
    static let sendBound = Duration.seconds(3)
    static let deadline = Duration.seconds(2)
    static let wifi = NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "en0")
    static let cellular = NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "pdp_ip0")
    static let otherCellular = NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "pdp_ip1")

    static func controller(
        _ transport: RecoveryTransport,
        _ clock: ManualTerminalClock,
        paths: ScriptedPathObserver,
        recovery: RecoveryLog? = nil
    ) -> TerminalSessionController {
        let controller = TerminalSessionController(
            client: transport,
            reconnectPolicy: TerminalTestDefaults.reconnectPolicy,
            heartbeatPolicy: HeartbeatPolicy(
                interval: interval,
                timeout: answerBound,
                sendTimeout: sendBound,
                handover: deadline
            ),
            timing: clock.timing,
            pathObserver: paths
        )
        controller.connect(
            hostText: TerminalTestDefaults.host,
            paneID: "fixture",
            credential: "valid-token",
            recovery: recovery
        )
        return controller
    }

    // Connected, with the monitor's first satisfied snapshot spent: that one
    // is only the baseline, so every `changed` after it is a real handover.
    static func connect(
        _ controller: TerminalSessionController,
        _ transport: RecoveryTransport,
        _ paths: ScriptedPathObserver
    ) async throws {
        try await waitUntilConnected(transport, controller)
        paths.emit(wifi)
        await settle()
    }

    // An ordinary round is under way, its send still in the outbound queue.
    static func beginRoundWithASuspendedSend(
        _ controller: TerminalSessionController,
        _ transport: RecoveryTransport,
        _ clock: ManualTerminalClock,
        _ paths: ScriptedPathObserver
    ) async throws {
        try await connect(controller, transport, paths)
        try await waitFor { await clock.hasWaiter(for: interval) }
        try await clock.resumeAll(for: interval)
        try await waitFor { await clock.hasWaiter(for: sendBound) }
    }
}
