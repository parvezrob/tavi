import UIKit

// The Ghostty surface belongs to the pane, not to the SwiftUI view that
// happens to be showing it.
//
// SwiftUI rebuilds a UIViewRepresentable's UIView whenever the
// representable's identity moves in the hierarchy, and the surface used to be
// rebuilt with it. The bridge saw its renderer replaced, told the controller
// the renderer had gone, and the controller dropped the resume point, paused
// the session and dialled the WebSocket again — twice around the generation
// counter per rebuild, on a good network, with nothing wrong and nothing in
// the log to blame (#111). The screen went with it: the freed surface took
// the scrollback, and only the redial's repaint brought the text back.
//
// The owner hands the same surface to whichever container SwiftUI has just
// built, so a rebuild reaches neither the connection nor the person reading.
// What still ends a surface is the two things that mean it: another pane
// (Jump-to gives the session a new id, and no scrollback or half-parsed
// escape sequence may cross over, #108) and the screen actually leaving.
@MainActor
final class TerminalSurfaceOwner {
    private let bridge: TerminalIOBridge
    private(set) var surface: GhosttyTerminalSurfaceView?
    // The bridge epoch this surface was installed under. It is held here
    // rather than on the container because only the surface is stable.
    private(set) var token: TerminalIOBridge.RendererToken?
    private var sessionID: Int?
    private var isActive: Bool?
    private var pendingRelease: Task<Void, Never>?

    init(bridge: TerminalIOBridge) {
        self.bridge = bridge
    }

    isolated deinit {
        pendingRelease?.cancel()
        surface?.shutdown()
    }

    // The surface this pane already has, or nil when the caller must build
    // one. A different session is a different pane, so its surface goes.
    func reusableSurface(for sessionID: Int) -> GhosttyTerminalSurfaceView? {
        pendingRelease?.cancel()
        pendingRelease = nil
        guard self.sessionID == sessionID else {
            release()
            return nil
        }
        return surface
    }

    func adopt(
        _ surface: GhosttyTerminalSurfaceView,
        token: TerminalIOBridge.RendererToken,
        sessionID: Int
    ) {
        self.surface = surface
        self.token = token
        self.sessionID = sessionID
        isActive = nil
    }

    // setActive re-focuses, re-checks occlusion and draws synchronously on
    // the main thread, so only a real change is worth it (#68 phone 2). The
    // flag lives with the surface, so a rebuilt container cannot lose track
    // of what was already applied and force the draw again.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        surface?.setActive(active)
    }

    // A container going away is not the screen going away: on a rebuild
    // SwiftUI makes the replacement in the same update and it adopts this
    // surface. Only a surface nobody has taken by the next turn means the
    // terminal has really left, and that is what stops the session.
    func containerWentAway() {
        guard surface != nil, pendingRelease == nil else { return }
        pendingRelease = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            pendingRelease = nil
            guard surface?.superview == nil else { return }
            release()
        }
    }

    func release() {
        pendingRelease?.cancel()
        pendingRelease = nil
        guard let surface else { return }
        self.surface = nil
        sessionID = nil
        isActive = nil
        // Cleanup first: the bridge must end this surface's epoch before
        // shutdown() drops what the pump still holds.
        if let token {
            self.token = nil
            bridge.removeTerminal(token)
        }
        surface.shutdown()
        surface.removeFromSuperview()
    }
}
