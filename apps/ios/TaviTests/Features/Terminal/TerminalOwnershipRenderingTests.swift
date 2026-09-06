import SwiftUI
@testable import Tavi
import XCTest

// The one thing about a taken-over terminal that only a person can judge:
// the last screen is still there and the bar underneath says what to do
// about it (#108). Everything on screen is synthetic — no host, no
// credential, no real pane. The capture is an attachment for the owner's
// visual pass; the assertions around it are the automated part.
@MainActor
final class TerminalOwnershipRenderingTests: XCTestCase {
    private static let screenText = "Test terminal"
    private static let lastLine = "The last screen remains readable."

    func testTakenOverTerminalKeepsItsScreenAndRecoveryMessage() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let controller = TerminalSessionController()
        let screen = UIHostingController(rootView: AnyView(terminal(controller)))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = screen
        window.makeKeyAndVisible()

        var failure: (any Error)?
        do {
            try await capture(controller, screen, window)
        } catch {
            failure = error
        }
        await dismantle(controller, screen, window, restoring: previousWindow)
        if let failure { throw failure }
    }

    private func terminal(_ controller: TerminalSessionController) -> some View {
        TerminalSessionView(
            controller: controller,
            computerName: "Test computer",
            developmentBootstrap: TerminalDevelopmentBootstrap(agentPaneID: nil, rendererStressChunks: nil)
        )
        .preferredColorScheme(.dark)
    }

    private func capture(
        _ controller: TerminalSessionController,
        _ screen: UIHostingController<AnyView>,
        _ window: UIWindow
    ) async throws {
        try await waitUntil("the renderer to attach") { controller.bridge.hasRenderer }
        controller.renderDevelopmentOutput(
            "\u{1B}[2J\u{1B}[H\(Self.screenText)\r\n\(Self.lastLine)\r\n"
        )
        // The renderer's own transcript is the readiness signal: it is
        // published from the grid after Ghostty has parsed the output. The
        // attachment below verifies the visible result.
        try await waitUntil("the synthetic output to reach the grid") {
            controller.latestTranscript.contains(Self.lastLine)
        }

        controller.handleTakeover()
        controller.bridge.dismissKeyboard()
        try await waitUntil("the takeover to reach the screen") {
            controller.connectionState == .superseded
        }
        screen.view.layoutIfNeeded()

        XCTAssertFalse(controller.connectionState.canSubmitInput)
        // The last screen stays: losing the attachment does not tear the
        // renderer down.
        XCTAssertTrue(controller.bridge.hasRenderer)
        XCTAssertTrue(controller.latestTranscript.contains(Self.screenText))

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Taken-over terminal at iPhone 12 Pro width"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // Replacing the hosted content is what makes SwiftUI run
    // dismantleUIView, which frees the Ghostty surface. Without it the
    // surface outlives the test and its deinit asserts.
    private func dismantle(
        _ controller: TerminalSessionController,
        _ screen: UIHostingController<AnyView>,
        _ window: UIWindow,
        restoring previousWindow: UIWindow?
    ) async {
        screen.rootView = AnyView(EmptyView())
        screen.view.setNeedsLayout()
        screen.view.layoutIfNeeded()
        try? await waitUntil("the renderer to detach") { !controller.bridge.hasRenderer }
        XCTAssertFalse(controller.bridge.hasRenderer, "the terminal surface outlived the test")
        controller.stop()
        window.isHidden = true
        window.rootViewController = nil
        previousWindow?.makeKey()
    }

    // Bounded and observable: SwiftUI's layout pass and Ghostty's parse both
    // land on other turns, so this polls rather than sleeping for a number
    // somebody guessed.
    private func waitUntil(
        _ description: String,
        within timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while ContinuousClock().now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(description)")
        throw TerminalTestFailure()
    }
}
