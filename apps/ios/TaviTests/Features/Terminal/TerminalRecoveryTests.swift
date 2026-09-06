import Foundation
@testable import Tavi
import Testing

// Foreground recovery through the real TerminalSessionController (#107):
// the retry handle, the ready budget, the backoff, and what a route change
// is allowed to do to an attempt in progress. Every wait is resumed by the
// test; nothing here depends on elapsed time.
@MainActor
struct TerminalRecoveryTests {
    private static let host = "https://mac.tailnet.ts.net"
    private static let deadline = Duration.seconds(12)
    // One second of retry delay, less up to 20 % of jitter.
    private static let retryDelay = Duration.milliseconds(800)...Duration.seconds(1)
    private static let ready = TerminalTransportEvent.message(
        .ready(stream: "epoch-a", offset: 0, resumed: false)
    )

    private func start(
        _ transport: RecoveryTransport,
        _ clock: ManualTerminalClock,
        paths: ScriptedPathObserver = ScriptedPathObserver()
    ) -> TerminalSessionController {
        let controller = TerminalSessionController(
            client: transport,
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .seconds(1),
                maximumDelay: .seconds(1),
                multiplier: 1,
                connectDeadline: Self.deadline,
                sustainedHealthInterval: .seconds(30)
            ),
            timing: clock.timing,
            pathObserver: paths
        )
        controller.connect(hostText: Self.host, paneID: "fixture", credential: "valid-token")
        return controller
    }

    // Cycles the attempt in progress at its ready deadline and lets the
    // scheduled retry dial, releasing the intentional close it performs.
    // One deadline is armed per dial, so waiting for the two counts to meet
    // is what says the live deadline — not a cancelled predecessor — is the
    // one about to be resumed.
    private func cycleAndRedial(_ transport: RecoveryTransport, _ clock: ManualTerminalClock) async throws {
        try await waitForDeadline(transport, clock)
        try await clock.resumeAll(for: Self.deadline)
        try await redial(transport, clock)
    }

    private func waitForDeadline(_ transport: RecoveryTransport, _ clock: ManualTerminalClock) async throws {
        try await waitFor {
            let armed = await clock.timesScheduled(Self.deadline)
            let dials = await transport.connectCount
            return armed == dials
        }
    }

    private func redial(_ transport: RecoveryTransport, _ clock: ManualTerminalClock) async throws {
        let dials = await transport.connectCount
        try await waitFor { await clock.hasWaiter(within: Self.retryDelay) }
        try await clock.resumeAll(within: Self.retryDelay)
        try await waitFor {
            let gated = await transport.isGated
            let dialled = await transport.connectCount
            return gated || dialled > dials
        }
        await transport.releaseDisconnect()
        try await waitFor { await transport.connectCount > dials }
    }

    // MARK: - The stale retry handle

    // The wedge #107 reproduced: the retry cancels the old dial's handle
    // without releasing it, the superseded receive loop reports the
    // intentional close, and every later failure finds a non-nil handle
    // and does nothing at all — Connecting, forever.
    @Test
    func aSupersededCloseNeverSuppressesTheNextDialWhileConnecting() async throws {
        let transport = RecoveryTransport(ordering: .beforeDisconnectReturns)
        let clock = ManualTerminalClock()
        let controller = start(transport, clock)

        try await withCleanup(controller, transport) {
            try await waitFor { await transport.connectCount == 1 }
            try await cycleAndRedial(transport, clock)
            #expect(await transport.connectCount == 2)
            #expect(controller.connectionState == .connecting)

            // The second attempt fails while it is still Connecting. It must
            // dial a third time.
            try await cycleAndRedial(transport, clock)
            #expect(await transport.connectCount == 3)
            #expect(controller.connectionState == .connecting)
        }
    }

    @Test
    func aSupersededCloseNeverSuppressesTheNextDialAfterReady() async throws {
        let transport = RecoveryTransport(ordering: .beforeDisconnectReturns)
        let clock = ManualTerminalClock()
        let controller = start(transport, clock)

        try await withCleanup(controller, transport) {
            try await waitFor { await transport.connectCount == 1 }
            try await cycleAndRedial(transport, clock)

            // This one succeeds, and then the host goes away.
            await transport.emit(Self.ready)
            try await waitFor { controller.connectionState == .connected }
            // The first attempt already cost one, and a connection this brief
            // does not clear the backoff.
            await transport.emit(.disconnected)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 2) }
            try await redial(transport, clock)

            #expect(await transport.connectCount == 3)
            // The dial that replaced the failed one is dialling, not failing:
            // an intentional close with no receive loop left to hear it
            // belongs to nobody.
            await settle()
            #expect(controller.connectionState == .connecting)
        }
    }

    // The other ordering: disconnect() returns first and the superseded
    // loop is told afterwards. The late close belongs to a connection that
    // no longer exists and must not touch the dial that replaced it.
    @Test
    func aCloseDeliveredAfterTheIntentionalDisconnectCannotDisturbTheNewDial() async throws {
        let transport = RecoveryTransport(ordering: .afterDisconnectReturns)
        let clock = ManualTerminalClock()
        let controller = start(transport, clock)

        try await withCleanup(controller, transport) {
            try await waitFor { await transport.connectCount == 1 }
            try await cycleAndRedial(transport, clock)
            await settle()

            await transport.deliverPendingClose()
            await settle()
            #expect(await transport.connectCount == 2)
            #expect(controller.connectionState == .connecting)

            await transport.emit(Self.ready)
            try await waitFor { controller.connectionState == .connected }
        }
    }

    // MARK: - The ready budget

    // An isolated run of the real host with a four-second agent lookup lost
    // every attempt to the old three-second cutoff and delivered ready at
    // 4007 ms to a client that waited longer (#107). The budgets are the
    // contract; the run below is that a dial nobody cut off stays usable.
    @Test
    func theReadyBudgetOutlastsAFourSecondHostAndStaysFinite() async throws {
        let budget = ReconnectPolicy.terminalDefault.connectDeadline
        #expect(budget > .seconds(4))
        // Above the TCP connection budget, which is all NetworkWebSocketTask
        // applies, so this is the one bound on TLS, the upgrade and the wait
        // for ready — and it stays finite.
        #expect(budget > .seconds(ReconnectPolicy.terminalTCPConnectionTimeout))
        #expect(budget <= .seconds(20))

        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = TerminalSessionController(
            client: transport,
            reconnectPolicy: .terminalDefault,
            timing: clock.timing
        )
        controller.connect(hostText: Self.host, paneID: "fixture", credential: "valid-token")

        try await withCleanup(controller, transport) {
            try await waitFor { await transport.connectCount == 1 }
            try await waitFor { await clock.hasWaiter(for: budget) }
            #expect(controller.connectionState == .connecting)

            await transport.emit(Self.ready)
            try await waitFor { controller.connectionState == .connected }

            // And the connection is usable, not merely labelled connected.
            controller.bridge.receiveTerminalInput(Data("ls\r".utf8))
            try await waitFor { await transport.inputMessages == ["ls\r"] }
            #expect(await transport.connectCount == 1)
        }
    }

    // A ready that lands after the deadline fired, while the retry is still
    // waiting out its delay, is a success: the scheduled dial would tear
    // down a socket that has just proved itself.
    @Test
    func aReadyDuringTheRetryDelayKeepsTheConnectionItProved() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = start(transport, clock)

        try await withCleanup(controller, transport) {
            try await waitFor { await transport.connectCount == 1 }
            try await waitForDeadline(transport, clock)
            try await clock.resumeAll(for: Self.deadline)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
            try await waitFor { await clock.hasWaiter(within: Self.retryDelay) }

            await transport.emit(Self.ready)
            try await waitFor { controller.connectionState == .connected }

            // The scheduled teardown is gone, not merely late.
            try await waitFor { await clock.hasWaiter(within: Self.retryDelay) == false }
            await settle()
            #expect(controller.connectionState == .connected)
            #expect(await transport.connectCount == 1)
        }
    }

    // MARK: - Backoff

    // A link that says ready and dies keeps its place on the schedule; only
    // a connection that holds for the documented period clears it.
    @Test
    func repeatedFlapsKeepBackingOffInsteadOfReturningToTheShortestDelay() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = start(transport, clock)

        try await withCleanup(controller, transport) {
            for attempt in 1...3 {
                try await waitFor { await transport.connectCount == attempt }
                await transport.emit(Self.ready)
                try await waitFor { controller.connectionState == .connected }
                await transport.emit(.disconnected)
                try await waitFor { controller.connectionState == .reconnecting(attempt: attempt) }
                try await redial(transport, clock)
            }
        }
    }

    @Test
    func aConnectionThatHeldForTheHealthPeriodStartsTheBackoffOver() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = start(transport, clock)

        try await withCleanup(controller, transport) {
            // One failed attempt puts the backoff at attempt 1.
            try await waitFor { await transport.connectCount == 1 }
            try await cycleAndRedial(transport, clock)

            await transport.emit(Self.ready)
            try await waitFor { controller.connectionState == .connected }
            clock.advance(by: .seconds(30))
            await transport.emit(.disconnected)

            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
        }
    }

    @Test
    func aConnectionThatFellShortOfTheHealthPeriodKeepsItsPlace() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = start(transport, clock)

        try await withCleanup(controller, transport) {
            try await waitFor { await transport.connectCount == 1 }
            try await cycleAndRedial(transport, clock)

            await transport.emit(Self.ready)
            try await waitFor { controller.connectionState == .connected }
            clock.advance(by: .seconds(29))
            await transport.emit(.disconnected)

            try await waitFor { controller.connectionState == .reconnecting(attempt: 2) }
        }
    }

    // MARK: - Route chatter

    // On cellular the interface list changes at every handover. A dial in
    // progress owns its ready budget: restarting it handed it a fresh
    // deadline each time, so a route that flapped kept a reachable host
    // from ever finishing (#107).
    @Test
    func routeChatterDoesNotRestartAStillConnectingAttempt() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let controller = start(transport, clock, paths: paths)

        try await withCleanup(controller, transport) {
            try await waitFor { await transport.connectCount == 1 }
            try await waitFor { await clock.timesScheduled(Self.deadline) == 1 }

            paths.emit(NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "en0"))
            await settle()
            paths.emit(NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "pdp_ip0"))
            await settle()

            #expect(await transport.connectCount == 1)
            #expect(await clock.timesScheduled(Self.deadline) == 1)
            #expect(controller.connectionState == .connecting)

            // The original attempt finishes on its own budget.
            await transport.emit(Self.ready)
            try await waitFor { controller.connectionState == .connected }
        }
    }

    // MARK: - Blackout

    // Thirty seconds of nothing, then the link comes back: the same agent,
    // resumed at the exact byte the phone had, and not one keystroke sent
    // twice (PRD §7.13, principle 11).
    @Test
    func aThirtySecondBlackoutResumesTheSameAgentAndReplaysNothing() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = start(transport, clock)

        try await withCleanup(controller, transport) {
            try await waitFor { await transport.connectCount == 1 }
            await transport.emit(Self.ready)
            try await waitFor { controller.connectionState == .connected }
            await transport.emit(.message(.outputChunk(offset: 0, data: Data("hello".utf8))))
            await transport.emit(.message(.outputChunk(offset: 5, data: Data(" world".utf8))))
            controller.bridge.receiveTerminalInput(Data("deploy\r".utf8))
            try await waitFor { await transport.inputMessages == ["deploy\r"] }

            await transport.emit(.disconnected)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }

            // Three attempts that reach nobody, each written off at its own
            // deadline: thirty-six seconds of blackout.
            for _ in 0..<3 {
                try await redial(transport, clock)
                clock.advance(by: Self.deadline)
                try await waitForDeadline(transport, clock)
                try await clock.resumeAll(for: Self.deadline)
            }
            try await redial(transport, clock)
            await transport.emit(.message(.ready(stream: "epoch-a", offset: 11, resumed: true)))
            try await waitFor { controller.connectionState == .connected }

            #expect(controller.currentPaneID == "fixture")
            let resumes = await transport.connectResumes
            #expect(resumes.first ?? nil == nil)
            #expect(resumes.last ?? nil == TerminalResumePoint(stream: "epoch-a", offset: 11))
            // Ambiguous input is never replayed; the person resends it.
            #expect(await transport.inputMessages == ["deploy\r"])

            // And the recovered terminal takes input again.
            controller.bridge.receiveTerminalInput(Data("ls\r".utf8))
            try await waitFor { await transport.inputMessages == ["deploy\r", "ls\r"] }
        }
    }
}
