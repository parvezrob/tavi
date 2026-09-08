import Foundation
@testable import Tavi
import Testing

// The 2 s handover check (#111 P2), through the real controller: an
// interface change asks the round in flight rather than replacing it, the
// deadline it lands on is absolute and covers send and pong together, and
// the outcome is named in the connection log. Every wait is resumed by the
// test; nothing here depends on elapsed time.
@MainActor
struct TerminalHandoverTests {
    private static let interval = Duration.seconds(10)
    private static let answerBound = Duration.seconds(5)
    private static let sendBound = Duration.seconds(3)
    private static let handover = Duration.seconds(2)
    private static let wifi = NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "en0")
    private static let cellular = NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "pdp_ip0")
    private static let otherCellular = NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "pdp_ip1")

    private func makeController(
        _ transport: RecoveryTransport,
        _ clock: ManualTerminalClock,
        paths: ScriptedPathObserver,
        recovery: RecoveryLog? = nil
    ) -> TerminalSessionController {
        let controller = TerminalSessionController(
            client: transport,
            reconnectPolicy: TerminalTestDefaults.reconnectPolicy,
            heartbeatPolicy: HeartbeatPolicy(
                interval: Self.interval,
                timeout: Self.answerBound,
                sendTimeout: Self.sendBound,
                handover: Self.handover
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
    // is only the baseline, so every `changed` below is a real handover.
    private func connect(
        _ controller: TerminalSessionController,
        _ transport: RecoveryTransport,
        _ paths: ScriptedPathObserver
    ) async throws {
        try await waitUntilConnected(transport, controller)
        paths.emit(Self.wifi)
        await settle()
    }

    // An ordinary round is under way, its send still in the outbound queue.
    private func beginRoundWithASuspendedSend(
        _ controller: TerminalSessionController,
        _ transport: RecoveryTransport,
        _ clock: ManualTerminalClock,
        _ paths: ScriptedPathObserver
    ) async throws {
        try await connect(controller, transport, paths)
        try await waitFor { await clock.hasWaiter(for: Self.interval) }
        try await clock.resumeAll(for: Self.interval)
        try await waitFor { await clock.hasWaiter(for: Self.sendBound) }
    }

    // MARK: - The send half of the budget

    // The check is one deadline over both halves, so a challenge whose ping
    // never leaves the queue is a failed handover at 2 s — not at the 3 s
    // the queue would otherwise have had.
    @Test
    func aHandoverWhoseSendNeverCompletesCyclesAtTheHandoverDeadline() async throws {
        let transport = RecoveryTransport(hangsSends: true)
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let recovery = RecoveryLog(pathObserver: ScriptedPathObserver())
        let controller = makeController(transport, clock, paths: paths, recovery: recovery)

        try await withCleanup(controller, transport) {
            try await beginRoundWithASuspendedSend(controller, transport, clock, paths)

            paths.emit(Self.cellular)
            try await waitFor { await clock.hasWaiter(for: Self.handover) }
            #expect(await clock.hasWaiter(for: Self.sendBound) == false)

            try await clock.resumeAll(for: Self.handover)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }

            let failure = try #require(recovery.ring.first { $0.kind == .handoverFailed })
            #expect(failure.reason == .terminal(.handoverSendStalled))
            #expect(recovery.ring.last?.kind == .cycling)
            #expect(recovery.ring.last?.reason == .terminal(.handoverSendStalled))
        }
    }

    // The 2 s is measured from the path change, not from each half in turn:
    // a send that lands 0.1 s before the deadline leaves the host 0.1 s to
    // answer, never a fresh answer budget.
    @Test
    func aSendCompletingLateLeavesThePongOnlyWhatIsLeftOfTheDeadline() async throws {
        let transport = RecoveryTransport(hangsSends: true)
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let controller = makeController(transport, clock, paths: paths)

        try await withCleanup(controller, transport) {
            try await beginRoundWithASuspendedSend(controller, transport, clock, paths)

            paths.emit(Self.cellular)
            try await waitFor { await clock.hasWaiter(for: Self.handover) }

            clock.advance(by: .milliseconds(1_900))
            await transport.releaseSend()
            try await waitFor { await clock.hasWaiter(for: .milliseconds(100)) }
            #expect(await clock.timesScheduled(Self.answerBound) == 0)
            #expect(controller.connectionState == .connected)

            try await clock.resumeAll(for: .milliseconds(100))
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
        }
    }

    // MARK: - Coalescing

    // A handover flaps: the interface list changes again and again while the
    // check is outstanding. The earliest deadline stands and there is still
    // exactly one round — a fresh round per event would ask a stalled queue
    // to carry three pings before any of them could be answered.
    @Test
    func flappingDuringAChallengeKeepsOneRoundAndItsEarliestDeadline() async throws {
        let transport = RecoveryTransport(hangsSends: true)
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let controller = makeController(transport, clock, paths: paths)

        try await withCleanup(controller, transport) {
            try await beginRoundWithASuspendedSend(controller, transport, clock, paths)

            paths.emit(Self.cellular)
            try await waitFor { await clock.timesScheduled(Self.handover) == 1 }

            clock.advance(by: .milliseconds(500))
            paths.emit(Self.otherCellular)
            await settle()
            clock.advance(by: .milliseconds(500))
            paths.emit(Self.cellular)
            await settle()

            #expect(await clock.timesScheduled(Self.handover) == 1)
            #expect(await transport.pingIdentifiers.count == 1)

            try await clock.resumeAll(for: Self.handover)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
            #expect(await transport.pingIdentifiers.count == 1)
        }
    }

    // A round already closer to its own deadline than the handover would put
    // it keeps that deadline: the check may only shorten a budget, never
    // lengthen one. Four seconds into a five-second answer, a handover ends
    // it at five, not at six.
    @Test
    func anOrdinaryRoundNearerItsDeadlineThanTheHandoverKeepsIt() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let recovery = RecoveryLog(pathObserver: ScriptedPathObserver())
        let controller = makeController(transport, clock, paths: paths, recovery: recovery)

        try await withCleanup(controller, transport) {
            try await connect(controller, transport, paths)
            try await waitFor { await clock.hasWaiter(for: Self.interval) }
            try await clock.resumeAll(for: Self.interval)
            try await waitFor { await clock.hasWaiter(for: Self.answerBound) }

            clock.advance(by: .seconds(4))
            paths.emit(Self.cellular)
            try await waitFor { await clock.hasWaiter(for: .seconds(1)) }
            #expect(await clock.timesScheduled(Self.handover) == 0)
            #expect(await transport.pingIdentifiers.count == 1)

            try await clock.resumeAll(for: .seconds(1))
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
            let failure = try #require(recovery.ring.first { $0.kind == .handoverFailed })
            #expect(failure.reason == .terminal(.handoverPongMissing))
        }
    }

    // MARK: - The slow peer

    // The whole point of the shorter budget: a host that answers inside it
    // keeps the socket, and the log says the handover was checked.
    @Test
    func aPeerAnsweringInsideTheDeadlinePassesAndIsRecordedAsChecked() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let recovery = RecoveryLog(pathObserver: ScriptedPathObserver())
        let controller = makeController(transport, clock, paths: paths, recovery: recovery)

        try await withCleanup(controller, transport) {
            try await connect(controller, transport, paths)
            paths.emit(Self.cellular)
            // Both halves of the challenge are bounded by the same 2 s, so
            // the second registration is the ping being on the wire and the
            // answer's half of the deadline standing.
            try await waitFor { await clock.timesScheduled(Self.handover) == 2 }
            #expect(await clock.timesScheduled(Self.answerBound) == 0)

            clock.advance(by: .milliseconds(1_900))
            let identifier = try #require(await transport.pingIdentifiers.last)
            await transport.emit(.message(.pong(identifier: identifier)))
            try await waitFor { await clock.hasWaiter(for: Self.handover) == false }

            #expect(controller.connectionState == .connected)
            let checked = try #require(recovery.ring.last)
            #expect(checked.kind == .handoverChecked)
            #expect(checked.generation == 1)
        }
    }

    // And a host 2.1 s away is a socket the handover broke.
    @Test
    func aPeerSlowerThanTheDeadlineCyclesTheConnection() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let recovery = RecoveryLog(pathObserver: ScriptedPathObserver())
        let controller = makeController(transport, clock, paths: paths, recovery: recovery)

        try await withCleanup(controller, transport) {
            try await connect(controller, transport, paths)
            paths.emit(Self.cellular)
            try await waitFor { await clock.timesScheduled(Self.handover) == 2 }

            clock.advance(by: .milliseconds(2_100))
            try await clock.resumeAll(for: Self.handover)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }

            let failure = try #require(recovery.ring.first { $0.kind == .handoverFailed })
            #expect(failure.reason == .terminal(.handoverPongMissing))
            #expect(recovery.ring.contains { $0.kind == .handoverChecked } == false)
        }
    }

    // MARK: - A close delivered mid-challenge

    // The ordering that wedges a state machine: the socket goes away while
    // the challenge is outstanding. One retry, the stream resumed at the
    // byte the phone had, and the round the dead socket owned takes nothing
    // with it — neither its late pong nor its deadline may touch the
    // replacement's heartbeat.
    @Test
    func aCloseMidChallengeRetriesOnceAndLeavesTheReplacementIntact() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let recovery = RecoveryLog(pathObserver: ScriptedPathObserver())
        let controller = makeController(transport, clock, paths: paths, recovery: recovery)

        try await withCleanup(controller, transport) {
            try await connect(controller, transport, paths)
            await transport.emit(.message(.outputChunk(offset: 0, data: Data("hello".utf8))))
            await transport.emit(.message(.outputChunk(offset: 5, data: Data(" world".utf8))))
            try await waitFor { recovery.counters[.terminal]?.acceptedOffset == 11 }

            paths.emit(Self.cellular)
            try await waitFor { await clock.timesScheduled(Self.handover) == 2 }
            let stale = try #require(await transport.pingIdentifiers.last)

            await transport.emit(.disconnected)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
            // The dead socket's deadline went with it.
            #expect(await clock.hasWaiter(for: Self.handover) == false)

            try await waitFor { await clock.hasWaiter(within: TerminalTestDefaults.retryDelay) }
            try await clock.resumeAll(within: TerminalTestDefaults.retryDelay)
            try await waitUntilListening(transport, after: 1)
            await transport.emit(.message(.ready(stream: "epoch-a", offset: 11, resumed: true)))
            try await waitFor { controller.connectionState == .connected }

            #expect(await transport.connectCount == 2)
            #expect(await transport.connectResumes.last ?? nil == TerminalResumePoint(stream: "epoch-a", offset: 11))

            // The old challenge's answer arrives on the new connection and
            // is nobody's: it may not be read as a passed handover.
            await transport.emit(.message(.pong(identifier: stale)))
            await settle()
            #expect(controller.connectionState == .connected)
            #expect(recovery.ring.contains { $0.kind == .handoverChecked } == false)

            // The replacement's own heartbeat is whole: its interval is
            // waiting, and it opens an ordinary round when that elapses.
            try await waitFor { await clock.hasWaiter(for: Self.interval) }
            try await clock.resumeAll(for: Self.interval)
            try await waitFor { await transport.pingIdentifiers.count == 2 }
            try await waitFor { await clock.hasWaiter(for: Self.answerBound) }
        }
    }
}
