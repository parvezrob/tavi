import Foundation
@testable import Tavi
import Testing

// Losing the terminal to another connection (#108). The host sends three
// independent signals — a coded error frame, the exact legacy sentence, and
// close 1000 with reason `superseded` — and any one of them must stop this
// client dead: no input, no automatic reclaim, and no claim that the agent
// exited, because it is still running. Only an explicit reopen attaches
// again.
@MainActor
struct TerminalTakeoverTests {
    private static let codedTakeover = TerminalTransportEvent.message(
        .error(message: TerminalWireProtocol.takeoverMessage, code: .superseded)
    )
    private static let legacyTakeover = TerminalTransportEvent.message(
        .error(message: TerminalWireProtocol.takeoverMessage, code: nil)
    )

    // MARK: - The three signals

    // The coded frame stands on its own: a close can be lost or arrive
    // seconds later, and by then this client would have redialled.
    @Test
    func aCodedTakeoverFrameEndsTheSessionWithoutWaitingForAClose() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            await transport.emit(Self.codedTakeover)
            try await waitFor { controller.connectionState == .superseded }

            await settle()
            #expect(await transport.connectCount == 1)
            #expect(await clock.hasWaiter(within: TerminalTestDefaults.retryDelay) == false)
            #expect(controller.connectionState.canSubmitInput == false)
            // Not "the terminal ended": the durable agent is still running.
            #expect(controller.connectionState != .ended)
            #expect(controller.needsConnectionConfiguration)
        }
    }

    // A host built before the code sends the sentence alone.
    @Test
    func theLegacyTakeoverSentenceAloneIsTheSameOutcome() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            await transport.emit(Self.legacyTakeover)
            try await waitFor { controller.connectionState == .superseded }

            await settle()
            #expect(await transport.connectCount == 1)
        }
    }

    // And the close on its own, when the frame never arrives.
    @Test
    func aSupersededCloseWithNoFrameIsStillATakeover() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            await transport.emit(.takenOver)
            try await waitFor { controller.connectionState == .superseded }

            await settle()
            #expect(await transport.connectCount == 1)
        }
    }

    // The host sends both. The second one lands on a session that is already
    // over and changes nothing — one dial, one outcome.
    @Test
    func theFrameAndItsCloseTogetherEndTheSessionExactlyOnce() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            await transport.emit(Self.codedTakeover)
            try await waitFor { controller.connectionState == .superseded }
            await transport.emit(.takenOver)
            await settle()

            #expect(controller.connectionState == .superseded)
            #expect(await transport.connectCount == 1)
        }
    }

    // The host's two takeover paths — a compatible resume it hands to the
    // newcomer, and a fresh replacement — send the same frame. A client that
    // held a resume point must not treat its own as the reclaimable one.
    @Test
    func aTakeoverAfterAResumeHitIsHandledLikeAnyOther() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            await transport.emit(.message(.outputChunk(offset: 0, data: Data("hello".utf8))))
            await transport.emit(.disconnected)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
            try await waitFor { await clock.hasWaiter(within: TerminalTestDefaults.retryDelay) }
            try await clock.resumeAll(within: TerminalTestDefaults.retryDelay)
            try await waitUntilListening(transport, after: 1)
            // The second dial carried the resume point, and the host gave
            // the attachment to somebody else anyway.
            #expect(await transport.connectResumes.last ?? nil == TerminalResumePoint(stream: "epoch-a", offset: 5))

            await transport.emit(Self.codedTakeover)
            try await waitFor { controller.connectionState == .superseded }
            await settle()
            #expect(await transport.connectCount == 2)
        }
    }

    // MARK: - No automatic reclamation

    @Test
    func neitherTheForegroundNorARouteChangeCanReclaimALostTerminal() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let controller = startedController(transport, clock, paths: paths)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            await transport.emit(Self.codedTakeover)
            try await waitFor { controller.connectionState == .superseded }

            controller.sceneWillResignActive()
            await settle()
            #expect(controller.connectionState == .superseded)
            controller.sceneDidBecomeActive()
            await settle()
            #expect(controller.connectionState == .superseded)

            paths.emit(NetworkPathSnapshot(isSatisfied: false, interfaceIdentity: "none"))
            await settle()
            paths.emit(NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "en0"))
            await settle()

            #expect(controller.connectionState == .superseded)
            #expect(await transport.connectCount == 1)
        }
    }

    @Test
    func aSupersededTerminalSendsNothingMore() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            controller.bridge.receiveTerminalInput(Data("deploy\r".utf8))
            try await waitFor { await transport.inputMessages == ["deploy\r"] }

            await transport.emit(Self.codedTakeover)
            try await waitFor { controller.connectionState == .superseded }

            controller.bridge.receiveTerminalInput(Data("ls\r".utf8))
            controller.paste("echo hi")
            controller.sendQuickKey(.interrupt)
            await settle()

            #expect(await transport.inputMessages == ["deploy\r"])
        }
    }

    // MARK: - Getting it back

    // Back, then open the agent again: an explicit reattach works, starts
    // from a fresh attach rather than the dead epoch, and replays nothing.
    @Test
    func openingTheTerminalAgainTakesItBackWithoutReplayingInput() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            controller.bridge.receiveTerminalInput(Data("deploy\r".utf8))
            try await waitFor { await transport.inputMessages == ["deploy\r"] }
            await transport.emit(Self.codedTakeover)
            try await waitFor { controller.connectionState == .superseded }

            controller.connect(hostText: TerminalTestDefaults.host, paneID: "fixture", credential: "valid-token")
            try await waitUntilListening(transport, after: 1)
            await transport.emit(.message(.ready(stream: "epoch-b", offset: 0, resumed: false)))
            try await waitFor { controller.connectionState == .connected }

            #expect(await transport.connectResumes.last ?? nil == nil)
            #expect(await transport.inputMessages == ["deploy\r"])

            controller.bridge.receiveTerminalInput(Data("ls\r".utf8))
            try await waitFor { await transport.inputMessages == ["deploy\r", "ls\r"] }
        }
    }

    // MARK: - Everything else stays recoverable

    @Test
    func anOrdinaryErrorFrameStillOnlyReportsItself() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            await transport.emit(.message(.error(message: "Invalid terminal message.", code: nil)))
            try await waitFor { controller.errorMessage == "Invalid terminal message." }

            await settle()
            #expect(controller.connectionState == .connected)
        }
    }

    // A code from a host newer than this build is additive, not fatal.
    @Test
    func anUnknownErrorCodeKeepsOrdinaryErrorBehaviour() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            let frame = #"{"type":"error","message":"Something new happened.","code":"quarantined"}"#
            let decoded = try JSONDecoder().decode(TerminalServerMessage.self, from: Data(frame.utf8))
            #expect(decoded == .error(message: "Something new happened.", code: nil))

            await transport.emit(.message(decoded))
            try await waitFor { controller.errorMessage == "Something new happened." }

            await settle()
            #expect(controller.connectionState == .connected)
        }
    }

    // MARK: - The state itself

    @Test
    func supersededIsFinalAndSurvivesEveryLifecycleAction() {
        #expect(TerminalConnectionReducer.reduce(.connected, action: .takenOver) == .superseded)
        #expect(TerminalConnectionReducer.reduce(.connecting, action: .takenOver) == .superseded)
        #expect(TerminalConnectionReducer.reduce(.ended, action: .takenOver) == .ended)
        #expect(TerminalConnectionReducer.reduce(.failed, action: .takenOver) == .failed)
        // The load-bearing one: a superseded session that became suspended
        // would be redialled by the next foreground.
        #expect(TerminalConnectionReducer.reduce(.superseded, action: .suspend) == .superseded)
        #expect(TerminalConnectionReducer.reduce(.superseded, action: .resume) == .superseded)
        #expect(TerminalConnectionReducer.reduce(.superseded, action: .networkLost) == .superseded)
        #expect(
            TerminalConnectionReducer.reduce(.superseded, action: .connectionLost(nextAttempt: 2))
                == .superseded
        )
        #expect(TerminalConnectionState.superseded.canSubmitInput == false)
        #expect(TerminalConnectionState.superseded.isFinal)
        // Only an explicit reattach leaves it.
        #expect(TerminalConnectionReducer.reduce(.superseded, action: .connect) == .connecting)
    }
}
