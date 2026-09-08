import Foundation
@testable import Tavi
import Testing

// The terminal heartbeat's two bounds (#107), through the real controller.
// The three budgets are deliberately different lengths so a test can say
// which one it is resuming — and prove which one was never armed.
@MainActor
struct TerminalHeartbeatTests {
    private static let host = "https://mac.tailnet.ts.net"
    private static let interval = Duration.seconds(10)
    private static let answerBound = Duration.seconds(6)
    private static let sendBound = Duration.seconds(2)
    // One second of retry delay, less up to 20 % of jitter.
    private static let retryDelay = Duration.milliseconds(800)...Duration.seconds(1)

    private func makeController(
        _ transport: RecoveryTransport,
        _ clock: ManualTerminalClock,
        paths: ScriptedPathObserver = ScriptedPathObserver()
    ) -> TerminalSessionController {
        TerminalSessionController(
            client: transport,
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .seconds(1),
                maximumDelay: .seconds(1),
                multiplier: 1,
                connectDeadline: .seconds(12)
            ),
            heartbeatPolicy: HeartbeatPolicy(
                interval: Self.interval,
                timeout: Self.answerBound,
                sendTimeout: Self.sendBound
            ),
            timing: clock.timing,
            pathObserver: paths
        )
    }

    // Connected, with the first interval spent, so every test starts at the
    // moment a round is under way.
    private func beginFirstRound(
        _ controller: TerminalSessionController,
        _ transport: RecoveryTransport,
        _ clock: ManualTerminalClock
    ) async throws {
        controller.connect(hostText: Self.host, paneID: "fixture", credential: "valid-token")
        try await waitFor { await transport.connectCount == 1 }
        await transport.emit(.message(.ready(stream: "epoch-a", offset: 0, resumed: false)))
        try await waitFor { controller.connectionState == .connected }
        try await waitFor { await clock.hasWaiter(for: Self.interval) }
        try await clock.resumeAll(for: Self.interval)
    }

    // A send that never completes is as dead as a silent host, and it has
    // to be caught by a bound of its own — the host's answer budget is not
    // running yet, because nothing has been asked.
    @Test
    func aHeartbeatSendThatNeverCompletesCyclesOnItsOwnBound() async throws {
        let transport = RecoveryTransport(hangsSends: true)
        let clock = ManualTerminalClock()
        let controller = makeController(transport, clock)

        try await withCleanup(controller, transport) {
            try await beginFirstRound(controller, transport, clock)
            try await waitFor { await transport.latestPingIdentifier != nil }
            try await waitFor { await clock.hasWaiter(for: Self.sendBound) }
            #expect(await clock.timesScheduled(Self.answerBound) == 0)

            try await clock.resumeAll(for: Self.sendBound)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
            #expect(controller.errorMessage?.contains("stopped responding") == true)
        }
    }

    // The host's budget starts when the ping is on the wire, not when it
    // was queued: a slow send used to spend the answer's time for it.
    @Test
    func theAnswerBoundIsArmedOnlyOnceThePingHasLeft() async throws {
        let transport = RecoveryTransport(hangsSends: true)
        let clock = ManualTerminalClock()
        let controller = makeController(transport, clock)

        try await withCleanup(controller, transport) {
            try await beginFirstRound(controller, transport, clock)
            try await waitFor { await transport.latestPingIdentifier != nil }
            await settle()
            #expect(await clock.timesScheduled(Self.answerBound) == 0)

            await transport.releaseSend()
            try await waitFor { await clock.hasWaiter(for: Self.answerBound) }
            #expect(controller.connectionState == .connected)
        }
    }

    // A pong that arrives while the send is still resuming ends the round
    // healthy: no answer bound is armed for a question already answered.
    @Test
    func aPongThatBeatsTheSendContinuationEndsTheRoundHealthy() async throws {
        let transport = RecoveryTransport(hangsSends: true)
        let clock = ManualTerminalClock()
        let controller = makeController(transport, clock)

        try await withCleanup(controller, transport) {
            try await beginFirstRound(controller, transport, clock)
            let identifier = try await requirePingIdentifier(transport)
            await transport.emit(.message(.pong(identifier: identifier)))
            await settle()
            await transport.releaseSend()
            await settle()

            #expect(controller.connectionState == .connected)
            #expect(await clock.timesScheduled(Self.answerBound) == 0)
            // And the round finished, so the next one is waiting its interval.
            try await waitFor { await clock.hasWaiter(for: Self.interval) }
        }
    }

    // A reply says the host is alive. It says nothing about our own queue,
    // so it must not disarm the send bound: a serialized send that never
    // returns leaves the terminal Connected, accepting keystrokes that can
    // never leave, with no round and no bound left to notice (#107).
    @Test
    func aPongLeavesTheBoundOnOurOwnUnfinishedSendArmed() async throws {
        let transport = RecoveryTransport(hangsSends: true)
        let clock = ManualTerminalClock()
        let controller = makeController(transport, clock)

        try await withCleanup(controller, transport) {
            try await beginFirstRound(controller, transport, clock)
            let identifier = try await requirePingIdentifier(transport)
            await transport.emit(.message(.pong(identifier: identifier)))
            await settle()

            // The answer released its own bound and nothing else.
            #expect(await clock.hasWaiter(for: Self.answerBound) == false)
            #expect(await clock.hasWaiter(for: Self.sendBound))

            // Someone types while the queue is stuck behind that send.
            controller.bridge.receiveTerminalInput(Data("deploy\r".utf8))
            await settle()

            try await clock.resumeAll(for: Self.sendBound)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
            #expect(controller.errorMessage?.contains("stopped responding") == true)
            // Recovery is scheduled while the queued keystrokes remain unsent.
            try await waitFor { await clock.hasWaiter(within: Self.retryDelay) }
            #expect(await transport.inputMessages == [])
        }
    }

    // A pong ends the round there and then. Waiting the answer budget out
    // anyway made a healthy cadence interval + timeout instead of the
    // interval the PRD promises (#107).
    @Test
    func aPongClosesTheRoundSoTheNextOneIsOneIntervalAway() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = makeController(transport, clock)

        try await withCleanup(controller, transport) {
            try await beginFirstRound(controller, transport, clock)
            let identifier = try await requirePingIdentifier(transport)
            try await waitFor { await clock.hasWaiter(for: Self.answerBound) }
            await transport.emit(.message(.pong(identifier: identifier)))

            // The answer bound is released, and the loop is back on the
            // interval rather than sitting out the rest of the budget.
            try await waitFor { await clock.hasWaiter(for: Self.answerBound) == false }
            try await waitFor { await clock.hasWaiter(for: Self.interval) }
            #expect(controller.connectionState == .connected)
            #expect(controller.errorMessage == nil)
        }
    }

    // A satisfied path change asks the round already under way rather than
    // opening a second one: one ping, one deadline, and the answer bounded
    // by what is left of it rather than by a fresh budget (#107, #111 P2).
    @Test
    func aPathChangeAsksTheRoundInFlightInsteadOfOpeningASecond() async throws {
        let transport = RecoveryTransport(hangsSends: true)
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let controller = makeController(transport, clock, paths: paths)

        try await withCleanup(controller, transport) {
            try await beginFirstRound(controller, transport, clock)
            try await waitFor { await clock.timesScheduled(Self.sendBound) == 1 }

            paths.emit(NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "en0"))
            await settle()
            paths.emit(NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "pdp_ip0"))
            try await waitFor { await clock.timesScheduled(Self.sendBound) == 2 }

            // That round's send finally lands. The answer it is still owed
            // is bounded by the round's own deadline, not by a new one.
            await transport.releaseSend()
            await settle()
            #expect(await clock.timesScheduled(Self.answerBound) == 0)
            #expect(await transport.pingIdentifiers.count == 1)
            #expect(controller.connectionState == .connected)
        }
    }

    // Nothing answers, and the connection is cycled at the answer bound.
    @Test
    func anUnansweredPingCyclesTheConnectionAtTheAnswerBound() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = makeController(transport, clock)

        try await withCleanup(controller, transport) {
            try await beginFirstRound(controller, transport, clock)
            _ = try await requirePingIdentifier(transport)
            try await waitFor { await clock.hasWaiter(for: Self.answerBound) }
            try await clock.resumeAll(for: Self.answerBound)

            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
            #expect(controller.errorMessage?.contains("stopped responding") == true)
        }
    }

    private func requirePingIdentifier(_ transport: RecoveryTransport) async throws -> String {
        try await waitFor { await transport.latestPingIdentifier != nil }
        guard let identifier = await transport.latestPingIdentifier else {
            throw TerminalTestFailure()
        }
        return identifier
    }
}
