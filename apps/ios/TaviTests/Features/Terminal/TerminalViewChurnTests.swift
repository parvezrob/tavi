import SwiftUI
@testable import Tavi
import XCTest

// The defect the owner chased for weeks (#111): the terminal froze and
// redialled while typing or scrolling, on a good network, with no transport
// event anywhere in the capture. The cause is in the view layer — SwiftUI
// rebuilding the representable's UIView — and the rule these tests hold is
// that a view-layer rebuild must reach neither the connection nor the screen.
// Everything below drives the real screen in a real window over a real
// Ghostty surface, with the transport and the clock injected.
@MainActor
final class TerminalViewChurnTests: XCTestCase {
    // Two separate reasons the home touches this screen: an ordinary redraw
    // (the `navigationDestination` closure runs again) and a rebuild (the
    // representable's identity moves, so SwiftUI makes a new UIView).
    @Observable
    final class HomeTick {
        var redraws = 0
        var rebuilds = 0
    }

    private struct ChurnHome: View {
        let controller: TerminalSessionController
        let tick: HomeTick
        @State private var presented = true

        var body: some View {
            NavigationStack {
                Text("home \(tick.redraws)")
                    .navigationDestination(isPresented: $presented) {
                        TerminalSessionView(
                            controller: controller,
                            developmentBootstrap: TerminalDevelopmentBootstrap(
                                agentPaneID: nil,
                                rendererStressChunks: nil
                            )
                        )
                        .id(tick.rebuilds)
                    }
            }
        }
    }

    func testASurfaceRebuildKeepsOneConnection() async throws {
        try await withStage { stage in
            let generation = stage.controller.connectionGeneration
            let dials = await stage.transport.connectCount

            for _ in 0..<3 {
                try await stage.rebuildSurface()
            }

            XCTAssertEqual(
                stage.controller.connectionGeneration,
                generation,
                "a surface rebuild advanced the connection generation"
            )
            let dialsAfter = await stage.transport.connectCount
            XCTAssertEqual(dialsAfter, dials, "a surface rebuild dialled the WebSocket again")
            XCTAssertEqual(stage.controller.connectionState, .connected)
        }
    }

    // The screen the person is reading is the thing a rebuild used to lose:
    // the old surface was freed, and only the redial's repaint brought the
    // text back. Nothing may be discarded and no byte may be skipped.
    func testASurfaceRebuildKeepsTheScreenAndTheResumePoint() async throws {
        try await withStage { stage in
            let first = "\u{1B}[2J\u{1B}[Hbefore the rebuild\r\n"
            await stage.transport.emit(.message(.outputChunk(offset: 0, data: Data(first.utf8))))
            try await stage.waitUntil("the first line to reach the screen") {
                stage.controller.latestTranscript.contains("before the rebuild")
            }

            try await stage.rebuildSurface()
            XCTAssertTrue(
                stage.controller.latestTranscript.contains("before the rebuild"),
                "the rebuild lost the screen the person was reading"
            )

            let second = "after the rebuild\r\n"
            await stage.transport.emit(
                .message(.outputChunk(offset: UInt64(first.utf8.count), data: Data(second.utf8)))
            )
            try await stage.waitUntil("the second line to reach the screen") {
                stage.controller.latestTranscript.contains("after the rebuild")
            }

            // A genuine disconnect afterwards proves what the session kept:
            // the resume point covers both chunks, so the host resends
            // neither and skips nothing.
            try await stage.forceReconnect()
            let resume = await stage.transport.connectResumes.last ?? nil
            XCTAssertEqual(
                resume,
                TerminalResumePoint(
                    stream: "epoch-a",
                    offset: UInt64(first.utf8.count + second.utf8.count)
                ),
                "the rebuild dropped the resume point"
            )
        }
    }

    func testATranscriptUpdateDoesNotTouchTheConnection() async throws {
        try await withStage { stage in
            let generation = stage.controller.connectionGeneration
            let dials = await stage.transport.connectCount

            for index in 0..<8 {
                await stage.transport.emit(
                    .message(.output("line \(index) of a talkative agent\r\n"))
                )
            }
            try await stage.waitUntil("the transcript to catch up") {
                stage.controller.latestTranscript.contains("line 7")
            }
            stage.tick.redraws += 1
            stage.layout()
            await settle()

            XCTAssertEqual(stage.controller.connectionGeneration, generation)
            let dialsAfter = await stage.transport.connectCount
            XCTAssertEqual(dialsAfter, dials)
            XCTAssertEqual(stage.controller.connectionState, .connected)
        }
    }

    // The keyboard is the everyday grid change: it takes height from the
    // terminal, the surface re-flows, and the host's pty must follow — over
    // the connection that is already open, including right after a rebuild.
    func testAGridChangeAfterARebuildResizesWithoutReconnecting() async throws {
        try await withStage { stage in
            try await stage.rebuildSurface()
            let generation = stage.controller.connectionGeneration
            let dials = await stage.transport.connectCount
            let resizes = await stage.resizeCount()

            stage.window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
            stage.layout()
            try await stage.waitUntil("the smaller grid to reach the host") {
                await stage.resizeCount() > resizes
            }

            XCTAssertEqual(stage.controller.connectionGeneration, generation)
            let dialsAfter = await stage.transport.connectCount
            XCTAssertEqual(dialsAfter, dials, "a grid change dialled the WebSocket again")
        }
    }

    // The other half of the rule: a surface that really goes — the screen
    // popped back to the home — still stops the session, and putting the
    // screen back still starts it.
    func testTheScreenGoingAwayPausesAndComingBackResumes() async throws {
        try await withStage { stage in
            let dials = await stage.transport.connectCount

            stage.screen.rootView = AnyView(EmptyView())
            stage.layout()
            try await stage.waitUntil("the session to pause") {
                stage.controller.connectionState == .suspended
            }
            XCTAssertFalse(stage.controller.bridge.hasRenderer)
            let dialsWhilePaused = await stage.transport.connectCount
            XCTAssertEqual(dialsWhilePaused, dials, "a paused session dialled")

            stage.screen.rootView = AnyView(
                ChurnHome(controller: stage.controller, tick: stage.tick)
            )
            stage.layout()
            try await stage.waitUntil("the screen to come back") { stage.controller.bridge.hasRenderer }
            try await stage.waitUntil("a fresh dial") {
                await stage.transport.connectCount == dials + 1
            }
            await stage.transport.emit(.message(.ready(stream: "epoch-b", offset: 0, resumed: false)))
            try await stage.waitUntil("the session to come back") {
                stage.controller.connectionState == .connected
            }
        }
    }

    // MARK: - Rig

    // A connected terminal on screen, torn down again whatever the body does:
    // the Ghostty surface asserts in its deinit if it outlives the test.
    private func withStage(_ body: (Stage) async throws -> Void) async throws {
        let stage = try Stage()
        var failure: (any Error)?
        do {
            try await stage.connect()
            try await body(stage)
        } catch {
            failure = error
        }
        await stage.finish()
        if let failure { throw failure }
    }

    @MainActor
    final class Stage {
        let controller: TerminalSessionController
        let screen: UIHostingController<AnyView>
        let tick = HomeTick()
        let transport = RecoveryTransport()
        let window: UIWindow
        private let clock = ManualTerminalClock()
        private let previousWindow: UIWindow?

        init() throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            previousWindow = scene.windows.first(where: \.isKeyWindow)
            controller = TerminalSessionController(
                client: transport,
                reconnectPolicy: TerminalTestDefaults.reconnectPolicy,
                timing: clock.timing,
                pathObserver: ScriptedPathObserver()
            )
            screen = UIHostingController(rootView: AnyView(EmptyView()))
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = screen
            window.makeKeyAndVisible()
            screen.rootView = AnyView(ChurnHome(controller: controller, tick: tick))
            layout()
        }

        func layout() {
            screen.view.setNeedsLayout()
            screen.view.layoutIfNeeded()
        }

        func connect() async throws {
            try await waitUntil("the first surface") { self.controller.bridge.hasRenderer }
            controller.connect(
                hostText: TerminalTestDefaults.host,
                paneID: "fixture",
                credential: "valid-token"
            )
            try await waitUntilConnected(transport, controller)
            try await waitUntil("the connected screen") { self.controller.bridge.hasRenderer }
            layout()
            await settle()
        }

        // What SwiftUI does when the representable's identity moves: the old
        // UIView is dismantled and a new one is made in the same update.
        func rebuildSurface() async throws {
            tick.rebuilds += 1
            layout()
            await settle()
            try await waitUntil("the rebuilt screen") { self.controller.bridge.hasRenderer }
            layout()
            await settle()
        }

        // How many pty resizes the host was told about, so a test can wait
        // for one without caring what the simulator's grid worked out to.
        func resizeCount() async -> Int {
            await transport.sentMessages.count { message in
                if case .resize = message { return true }
                return false
            }
        }

        // A real transport close and its retry, so the next dial's resume
        // request says what the session still held.
        func forceReconnect() async throws {
            let dials = await transport.connectCount
            await transport.emit(.disconnected)
            try await waitUntil("the retry to be scheduled") {
                await self.clock.hasWaiter(within: TerminalTestDefaults.retryDelay)
            }
            try await clock.resumeAll(within: TerminalTestDefaults.retryDelay)
            try await waitUntil("the redial") { await self.transport.connectCount == dials + 1 }
        }

        func waitUntil(
            _ description: String,
            within timeout: Duration = .seconds(5),
            _ condition: () async -> Bool
        ) async throws {
            let deadline = ContinuousClock().now.advanced(by: timeout)
            while ContinuousClock().now < deadline {
                if await condition() { return }
                await Task.yield()
            }
            XCTFail("Timed out waiting for \(description)")
            throw TerminalTestFailure()
        }

        func finish() async {
            screen.rootView = AnyView(EmptyView())
            layout()
            for _ in 0..<500 where controller.bridge.hasRenderer {
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(controller.bridge.hasRenderer, "the terminal surface outlived the test")
            controller.stop()
            await transport.releaseEverything()
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
    }
}
