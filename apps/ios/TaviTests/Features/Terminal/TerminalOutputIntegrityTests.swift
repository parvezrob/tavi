import Foundation
@testable import Tavi
import Testing

// What the resume offset is allowed to claim (#108). The protocol lets the
// host trim everything behind it, so the offset may only name bytes this
// client has really taken: durably queued, in order, for a surface that is
// still alive. Anything discarded before a surface took it drops the epoch
// and forces a repaint before anything else can be typed. The real
// controller and the real bridge run in every test below.
@MainActor
struct TerminalOutputIntegrityTests {
    // One frame's worth of output, at the protocol's frame bound.
    private static let chunkBytes = 64 * 1_024

    // Fills the absent-renderer queue past its bound, one frame at a time.
    private func floodPastTheBound(_ transport: RecoveryTransport) async {
        let chunk = Data(repeating: UInt8(ascii: "x"), count: Self.chunkBytes)
        var offset: UInt64 = 0
        for _ in 0...16 {
            await transport.emit(.message(.outputChunk(offset: offset, data: chunk)))
            offset += UInt64(Self.chunkBytes)
        }
    }

    // MARK: - The offset means what it says

    @Test
    func aLiveSurfaceGetsTheExactBytesAndTheOffsetPastThem() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)
        let renderer = SyntheticRenderer()
        renderer.install(into: controller.bridge)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            await transport.emit(.message(.outputChunk(offset: 0, data: Data("hello".utf8))))
            await transport.emit(.message(.outputChunk(offset: 5, data: Data(" world".utf8))))
            try await waitFor { renderer.acceptedText == "hello world" }

            await transport.emit(.disconnected)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
            try await waitFor { await clock.hasWaiter(within: TerminalTestDefaults.retryDelay) }
            try await clock.resumeAll(within: TerminalTestDefaults.retryDelay)
            try await waitFor { await transport.connectCount == 2 }

            #expect(
                await transport.connectResumes.last ?? nil
                    == TerminalResumePoint(stream: "epoch-a", offset: 11)
            )
            #expect(renderer.acceptedText == "hello world")
        }
    }

    // Bytes that arrive before the first surface are held in order and
    // handed over whole; nothing was lost, so nothing invalidates.
    @Test
    func outputHeldForASurfaceThatHasNotAttachedYetSurvivesInOrder() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)
        let renderer = SyntheticRenderer()

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            await transport.emit(.message(.outputChunk(offset: 0, data: Data("first ".utf8))))
            await transport.emit(.message(.outputChunk(offset: 6, data: Data("second".utf8))))
            // Both chunks are behind the controller before any surface
            // exists: the ask for a fourth event is what proves it.
            try await waitFor { await transport.receiveCount >= 4 }

            renderer.install(into: controller.bridge)
            #expect(renderer.acceptedText == "first second")
            await settle()
            // No repaint was needed, so no second dial happened.
            #expect(await transport.connectCount == 1)
            #expect(controller.connectionState == .connected)
        }
    }

    // MARK: - Discards

    // The bug this test exists for: with no surface, the bridge used to trim
    // its buffer while the controller had already told the host those bytes
    // were rendered. The host then trimmed them too, and they were gone.
    @Test
    func outputDiscardedWithNoSurfaceIsNeverAcknowledged() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)
        let renderer = SyntheticRenderer()

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            await floodPastTheBound(transport)
            // Nobody to paint for: the session stops receiving rather than
            // discarding more of what it cannot show.
            try await waitFor { controller.connectionState == .suspended }

            renderer.install(into: controller.bridge)
            try await waitFor { await transport.connectCount == 2 }
            // A fresh attach, so herdr repaints the whole pane.
            #expect(await transport.connectResumes.last ?? nil == nil)
            // And not one trimmed byte of the old stream reached the surface.
            #expect(renderer.accepted.isEmpty)
        }
    }

    // A surface that has been shut down accepts nothing. Saying so is the
    // difference between a hole in the screen and an honest repaint.
    @Test
    func aSurfaceThatRefusesTheBytesForcesAFreshAttachBeforeAnyInput() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)
        let renderer = SyntheticRenderer()
        renderer.install(into: controller.bridge)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            await transport.emit(.message(.outputChunk(offset: 0, data: Data("hello".utf8))))
            try await waitFor { renderer.acceptedText == "hello" }

            renderer.accepts = false
            await transport.emit(.message(.outputChunk(offset: 5, data: Data(" world".utf8))))
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
            #expect(controller.connectionState.canSubmitInput == false)

            try await waitFor { await clock.hasWaiter(within: TerminalTestDefaults.retryDelay) }
            try await clock.resumeAll(within: TerminalTestDefaults.retryDelay)
            try await waitFor { await transport.connectCount == 2 }
            #expect(await transport.connectResumes.last ?? nil == nil)
        }
    }

    // Nothing waits on the renderer: a refusal is answered on the same turn
    // the chunk arrives, so no acknowledgement can deadlock behind a frame.
    @Test
    func aRefusalIsAnsweredWithoutAwaitingTheRenderer() {
        let bridge = TerminalIOBridge()
        let renderer = SyntheticRenderer()
        renderer.install(into: bridge)
        renderer.accepts = false

        #expect(bridge.receiveRemoteOutput(Data("hello".utf8)) == false)
        renderer.accepts = true
        #expect(bridge.receiveRemoteOutput(Data("hello".utf8)))
    }

    // MARK: - Input

    // A dropped stream is not a reason to resend anything: ambiguous input
    // is the person's to repeat (PRD §7.13, principle 11).
    @Test
    func aForcedRepaintReplaysNoInput() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)
        let renderer = SyntheticRenderer()
        renderer.install(into: controller.bridge)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            controller.bridge.receiveTerminalInput(Data("deploy\r".utf8))
            try await waitFor { await transport.inputMessages == ["deploy\r"] }

            renderer.accepts = false
            await transport.emit(.message(.outputChunk(offset: 0, data: Data("hello".utf8))))
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
            try await waitFor { await clock.hasWaiter(within: TerminalTestDefaults.retryDelay) }
            try await clock.resumeAll(within: TerminalTestDefaults.retryDelay)
            try await waitUntilListening(transport, after: 1)
            renderer.accepts = true
            await transport.emit(.message(.ready(stream: "epoch-b", offset: 0, resumed: false)))
            try await waitFor { controller.connectionState == .connected }

            #expect(await transport.inputMessages == ["deploy\r"])
            controller.bridge.receiveTerminalInput(Data("ls\r".utf8))
            try await waitFor { await transport.inputMessages == ["deploy\r", "ls\r"] }
        }
    }

    // MARK: - Contiguity and the resume answer (#111)

    // P1 observes: a stream that skipped bytes is recorded and the chunk is
    // taken exactly as it always was.
    @Test
    func aChunkPastTheExpectedOffsetIsRecordedAsAGapAndStillAccepted() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let recovery = RecoveryLog(pathObserver: ScriptedPathObserver())
        let controller = startedController(transport, clock, recovery: recovery)
        let renderer = SyntheticRenderer()
        renderer.install(into: controller.bridge)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            await transport.emit(.message(.outputChunk(offset: 0, data: Data("hello".utf8))))
            try await waitFor { renderer.acceptedText == "hello" }
            await transport.emit(.message(.outputChunk(offset: 6, data: Data("world".utf8))))
            try await waitFor { renderer.acceptedText == "helloworld" }

            #expect(recovery.counters[.terminal]?.offsetGaps == 1)
            #expect(recovery.counters[.terminal]?.offsetOverlaps == 0)
            #expect(recovery.counters[.terminal]?.acceptedOffset == 11)
            #expect(controller.connectionState == .connected)
        }
    }

    @Test
    func aChunkBehindTheExpectedOffsetIsRecordedAsAnOverlap() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let recovery = RecoveryLog(pathObserver: ScriptedPathObserver())
        let controller = startedController(transport, clock, recovery: recovery)
        let renderer = SyntheticRenderer()
        renderer.install(into: controller.bridge)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            await transport.emit(.message(.outputChunk(offset: 0, data: Data("hello".utf8))))
            try await waitFor { renderer.acceptedText == "hello" }
            await transport.emit(.message(.outputChunk(offset: 4, data: Data("world".utf8))))
            try await waitFor { renderer.acceptedText == "helloworld" }

            #expect(recovery.counters[.terminal]?.offsetOverlaps == 1)
            #expect(recovery.counters[.terminal]?.offsetGaps == 0)
            #expect(recovery.counters[.terminal]?.acceptedOffset == 9)
        }
    }

    // The resume answer is compared with the question this dial asked; an
    // answer at another point is counted, never silently adopted.
    @Test
    func aResumedReadyAtTheRequestedPointIsAHit() async throws {
        try await withResumedReady(offset: 11, resumed: true) { recovery in
            #expect(recovery.counters[.terminal]?.resumeHits == 1)
            #expect(recovery.counters[.terminal]?.resumeMismatches == 0)
            #expect(recovery.counters[.terminal]?.acceptedOffset == 11)
        }
    }

    @Test
    func aResumedReadyAtAnotherOffsetIsAMismatch() async throws {
        try await withResumedReady(offset: 9, resumed: true) { recovery in
            #expect(recovery.counters[.terminal]?.resumeMismatches == 1)
            #expect(recovery.counters[.terminal]?.resumeHits == 0)
            #expect(recovery.counters[.terminal]?.acceptedOffset == 9)
        }
    }

    // A fresh attach legitimately restarts the accepted offset; the initial
    // dial is one too, so this is the second.
    @Test
    func aReadyThatDidNotResumeIsAMiss() async throws {
        try await withResumedReady(offset: 0, resumed: false) { recovery in
            #expect(recovery.counters[.terminal]?.resumeMisses == 2)
            #expect(recovery.counters[.terminal]?.resumeHits == 0)
            #expect(recovery.counters[.terminal]?.resumeMismatches == 0)
            #expect(recovery.counters[.terminal]?.acceptedOffset == 0)
        }
    }

    // Eleven bytes taken, the stream dropped, the redial asks to resume at
    // 11 — and the host answers what the caller chose.
    private func withResumedReady(
        offset: UInt64,
        resumed: Bool,
        _ assertions: (RecoveryLog) -> Void
    ) async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let recovery = RecoveryLog(pathObserver: ScriptedPathObserver())
        let controller = startedController(transport, clock, recovery: recovery)
        let renderer = SyntheticRenderer()
        renderer.install(into: controller.bridge)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            await transport.emit(.message(.outputChunk(offset: 0, data: Data("hello world".utf8))))
            try await waitFor { renderer.acceptedText == "hello world" }

            await transport.emit(.disconnected)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
            try await waitFor { await clock.hasWaiter(within: TerminalTestDefaults.retryDelay) }
            try await clock.resumeAll(within: TerminalTestDefaults.retryDelay)
            try await waitUntilListening(transport, after: 1)
            #expect(await transport.connectResumes.last ?? nil == TerminalResumePoint(stream: "epoch-a", offset: 11))

            await transport.emit(.message(.ready(stream: "epoch-a", offset: offset, resumed: resumed)))
            try await waitFor { controller.connectionState == .connected }
            assertions(recovery)
        }
    }
}
