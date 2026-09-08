import Foundation
@testable import Tavi
import Testing

// Which surface owns the terminal, and for how long (#108). A surface
// outlives its replacement's install and its session's end, and one screen
// is pointed at another pane by Jump-to without ever going away. The real
// controller and the real bridge run in every test below.
@MainActor
struct TerminalRendererOwnershipTests {
    // MARK: - Surface lifetime

    @Test
    func aTornDownSurfaceStopsTheSessionAndDropsItsResumePoint() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)
        let renderer = SyntheticRenderer()
        renderer.install(into: controller.bridge)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            await transport.emit(.message(.outputChunk(offset: 0, data: Data("hello".utf8))))
            try await waitFor { renderer.acceptedText == "hello" }

            renderer.remove(from: controller.bridge)
            try await waitFor { controller.connectionState == .suspended }

            // The popped screen receives nothing more, and the foreground
            // cannot bring it back while there is no surface.
            controller.sceneWillResignActive()
            controller.sceneDidBecomeActive()
            await settle()
            #expect(controller.connectionState == .suspended)
            #expect(await transport.connectCount == 1)

            // A new surface is what revives it, and it starts from a repaint.
            let replacement = SyntheticRenderer()
            replacement.install(into: controller.bridge)
            try await waitFor { await transport.connectCount == 2 }
            #expect(await transport.connectResumes.last ?? nil == nil)
        }
    }

    // SwiftUI builds the replacement before it dismantles the one it is
    // replacing. That install is itself the old surface's ending: the new
    // one inherits none of its bytes and starts from a fresh attach.
    @Test
    func aSurfaceInstalledOverALiveOneEndsTheOldEpochAndInheritsNothing() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)
        let first = SyntheticRenderer()
        first.install(into: controller.bridge)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            await transport.emit(.message(.outputChunk(offset: 0, data: Data("hello".utf8))))
            try await waitFor { first.acceptedText == "hello" }

            let second = SyntheticRenderer()
            second.install(into: controller.bridge)
            try await waitUntilListening(transport, after: 1)
            #expect(await transport.connectCount == 2)
            #expect(await transport.connectResumes.last ?? nil == nil)
            #expect(second.accepted.isEmpty)

            // The older surface's dismantle arrives afterwards and must be
            // inert: it cannot unhook the replacement or end its epoch.
            first.remove(from: controller.bridge)
            #expect(controller.bridge.hasRenderer)

            await transport.emit(.message(.ready(stream: "epoch-b", offset: 0, resumed: false)))
            try await waitFor { controller.connectionState == .connected }
            await transport.emit(.message(.outputChunk(offset: 0, data: Data("repainted".utf8))))
            try await waitFor { second.acceptedText == "repainted" }
            #expect(first.acceptedText == "hello")

            await transport.emit(.disconnected)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
            try await waitFor { await clock.hasWaiter(within: TerminalTestDefaults.retryDelay) }
            try await clock.resumeAll(within: TerminalTestDefaults.retryDelay)
            try await waitFor { await transport.connectCount == 3 }
            #expect(
                await transport.connectResumes.last ?? nil
                    == TerminalResumePoint(stream: "epoch-b", offset: 9)
            )
        }
    }

    // MARK: - One screen, another pane

    // Jump-to stops and reconnects the same controller while the screen
    // stays on top. Bytes the old pane had queued for a surface that never
    // attached must not be painted into the next pane.
    @Test
    func pendingBytesDoNotSurviveTheEndOfTheirSession() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)
        let renderer = SyntheticRenderer()

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            await transport.emit(.message(.outputChunk(offset: 0, data: Data("old pane".utf8))))
            try await waitFor { await transport.receiveCount >= 3 }

            controller.stop()
            renderer.install(into: controller.bridge)
            #expect(renderer.accepted.isEmpty)
        }
    }

    @Test
    func pendingBytesDoNotSurviveAConnectToAnotherPane() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)
        let renderer = SyntheticRenderer()

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            await transport.emit(.message(.outputChunk(offset: 0, data: Data("old pane".utf8))))
            try await waitFor { await transport.receiveCount >= 3 }

            try await switchPane(controller, transport, stream: "epoch-b")
            await transport.emit(.message(.outputChunk(offset: 0, data: Data("new pane".utf8))))
            // The new pane's first output is behind the controller, and
            // still has no surface to go to.
            try await waitFor { controller.firstPaintMilliseconds != nil }

            renderer.install(into: controller.bridge)
            #expect(renderer.acceptedText == "new pane")
        }
    }

    // The screen text is the previous pane's until the replacement surface
    // has drawn, and Files mentioned and the Preview button read it from the
    // controller rather than from the surface. A deliberate connect drops it
    // at once; an ordinary reconnect is the same pane and keeps it.
    @Test
    func aDeliberateConnectDropsThePreviousPanesScreenText() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)
        let old = SyntheticRenderer()
        old.install(into: controller.bridge)
        // Wired as AgentTerminalView wires a surface's transcript.
        let publishFromOldSurface: @MainActor (String) -> Void = controller.bridge.whileCurrentRenderer(
            token: { old.token },
            { controller.transcriptDidChange($0) }
        )

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            publishFromOldSurface("old pane: serving on http://localhost:3000")
            #expect(controller.latestTranscript.contains("old pane"))

            await transport.emit(.disconnected)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
            try await waitFor { await clock.hasWaiter(within: TerminalTestDefaults.retryDelay) }
            try await clock.resumeAll(within: TerminalTestDefaults.retryDelay)
            try await waitUntilListening(transport, after: 1)
            #expect(controller.latestTranscript.contains("old pane"))

            // Jump-to is another pane: nothing of the previous one may be
            // readable while the replacement surface is still connecting.
            controller.connect(
                hostText: TerminalTestDefaults.host,
                paneID: "other",
                credential: "valid-token"
            )
            #expect(controller.latestTranscript.isEmpty)
            #expect(controller.mentionedPorts.isEmpty)

            // And the retired surface cannot put it back: the same connect
            // ended its token.
            publishFromOldSurface("old pane: serving on http://localhost:3000")
            #expect(controller.latestTranscript.isEmpty)
        }
    }

    // The surface showing the old pane stops being the installed renderer at
    // the manual connect, so the new pane's output cannot land on it while
    // the view rebuilds the screen.
    @Test
    func theSurfaceShowingTheOldPaneIsRetiredByAManualConnect() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)
        let old = SyntheticRenderer()
        old.install(into: controller.bridge)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            await transport.emit(.message(.outputChunk(offset: 0, data: Data("old pane".utf8))))
            try await waitFor { old.acceptedText == "old pane" }

            try await switchPane(controller, transport, stream: "epoch-b")
            #expect(controller.bridge.hasRenderer == false)
            await transport.emit(.message(.outputChunk(offset: 0, data: Data("new pane".utf8))))

            let replacement = SyntheticRenderer()
            replacement.install(into: controller.bridge)
            try await waitFor { replacement.acceptedText == "new pane" }
            #expect(old.acceptedText == "old pane")
        }
    }

    // MARK: - Callbacks from a surface that is no longer installed

    // Every callback a surface makes runs through the bridge's guard and
    // reads its token when it fires rather than when it was wired.
    @Test
    func callbacksFromARetiredSurfaceAreInert() {
        let bridge = TerminalIOBridge()
        let first = SyntheticRenderer()
        first.install(into: bridge)
        let fromFirst = CallbackLog()
        let fromSecond = CallbackLog()
        let firstSays: @MainActor (String) -> Void = bridge.whileCurrentRenderer(
            token: { first.token },
            { fromFirst.record($0) }
        )
        firstSays("a")
        #expect(fromFirst.values == ["a"])

        // Installed over it, the way SwiftUI builds a replacement before it
        // dismantles the view it replaces.
        let second = SyntheticRenderer()
        second.install(into: bridge)
        let secondSays: @MainActor (String) -> Void = bridge.whileCurrentRenderer(
            token: { second.token },
            { fromSecond.record($0) }
        )
        firstSays("b")
        secondSays("b")
        #expect(fromFirst.values == ["a"])
        #expect(fromSecond.values == ["b"])

        // And a manual connect retires the surface still on screen.
        bridge.beginSession(1)
        secondSays("c")
        #expect(fromSecond.values == ["b"])
    }

    // Ghostty batches what the terminal wants to send and drains it on a
    // later main-actor turn, so a keystroke typed at the old pane can arrive
    // after the switch. It must not reach the new pane's pty.
    @Test
    func aKeystrokeBatchedBeforeAPaneSwitchNeverReachesTheNewPane() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)
        let old = SyntheticRenderer()
        old.install(into: controller.bridge)
        // Wired exactly as AgentTerminalView wires a surface's input.
        let bridge = controller.bridge
        let staleKeystroke: @MainActor (Data) -> Void = bridge.whileCurrentRenderer(
            token: { old.token },
            { bridge.receiveTerminalInput($0) }
        )

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            staleKeystroke(Data("ls\r".utf8))
            try await waitFor { await transport.inputMessages == ["ls\r"] }

            try await switchPane(controller, transport, stream: "epoch-b")
            staleKeystroke(Data("rm -rf .\r".utf8))
            await settle()
            #expect(await transport.inputMessages == ["ls\r"])
        }
    }

    // A session that is already paused has nothing left to invalidate.
    // Pausing it again used to bump the generation anyway, which is how one
    // view-layer event could cost the connection more than one dial (#111).
    @Test
    func pausingAnAlreadyPausedSessionCostsNothing() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let controller = startedController(transport, clock)
        let renderer = SyntheticRenderer()
        renderer.install(into: controller.bridge)

        try await withCleanup(controller, transport) {
            try await waitUntilConnected(transport, controller)
            renderer.remove(from: controller.bridge)
            try await waitFor { controller.connectionState == .suspended }
            let generation = controller.connectionGeneration

            controller.sceneWillResignActive()
            renderer.remove(from: controller.bridge)
            await settle()
            #expect(controller.connectionGeneration == generation)

            // And the resume that follows is still exactly one dial.
            controller.sceneDidBecomeActive()
            let replacement = SyntheticRenderer()
            replacement.install(into: controller.bridge)
            try await waitFor { await transport.connectCount == 2 }
            #expect(controller.connectionGeneration == generation + 1)
        }
    }

    // What SessionsView's Jump-to does to the one controller it keeps.
    private func switchPane(
        _ controller: TerminalSessionController,
        _ transport: RecoveryTransport,
        stream: String
    ) async throws {
        let dials = await transport.connectCount
        controller.connect(
            hostText: TerminalTestDefaults.host,
            paneID: "other",
            credential: "valid-token"
        )
        try await waitUntilListening(transport, after: dials)
        await transport.emit(.message(.ready(stream: stream, offset: 0, resumed: false)))
        try await waitFor { controller.connectionState == .connected }
    }
}

// What a guarded callback was allowed to say.
@MainActor
private final class CallbackLog {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}
