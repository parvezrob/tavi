import SwiftUI
import UIKit

// The Settings live preview (#51): a real Ghostty surface, not a SwiftUI
// imitation — the only honest way to show what a font size renders like.
// The surface is laid out at the remembered full-terminal viewport and the
// container clips it, so the grid it reports through onGridSizeChange is
// exactly the grid a real terminal would get at this size. It is fed one
// static sample; it never touches a host or real terminal content.
struct TerminalFontPreviewView: UIViewRepresentable {
    let fontSize: Double
    // Mirrors the real terminal's scene-phase handling: a Metal draw from a
    // backgrounding app gets the process killed, so the pump must suspend.
    let isActive: Bool
    let onGrid: @MainActor (TerminalGridSize) -> Void

    // Neutral sample bytes; a splash of SGR color proves rendering is live.
    private static let sample = Data(
        [
            "\u{1B}[32m➜\u{1B}[0m tavi \u{1B}[36mgit:(main)\u{1B}[0m claude",
            "\u{1B}[1mClaude Code\u{1B}[0m · working",
            "  Reading TerminalSessionView.swift…",
            "  Running tests: \u{1B}[32m81 passed\u{1B}[0m",
        ].joined(separator: "\r\n").utf8
    )

    func makeUIView(context: Context) -> PreviewContainer {
        let container = PreviewContainer()
        container.clipsToBounds = true
        container.backgroundColor = .black
        guard let runtime = try? GhosttyRuntime.shared.get(),
              let terminal = try? GhosttyTerminalSurfaceView(
                  runtime: runtime,
                  fontSize: fontSize,
                  onInput: { _ in },
                  onFailure: { _ in }
              ) else {
            // No renderer, no preview: the slider and grid readout row keep
            // working from the last known values; nothing here pretends.
            return container
        }
        terminal.acceptsKeyboardFocus = false
        terminal.isAccessibilityElement = false
        terminal.onGridSizeChange = gridConsumer
        // The terminal keeps this fixed viewport-sized frame; with no
        // autoresizing mask and no constraints, the container's layout
        // never stretches it — it only clips.
        terminal.autoresizingMask = []
        terminal.frame = CGRect(origin: .zero, size: TerminalViewportRecord.loadOrEstimate())
        container.addSubview(terminal)
        container.terminal = terminal
        terminal.setActive(isActive)
        container.isActive = isActive
        container.fontSize = fontSize
        terminal.receive(Self.sample)
        return container
    }

    func updateUIView(_ container: PreviewContainer, context: Context) {
        container.terminal?.onGridSizeChange = gridConsumer
        // setActive re-focuses, re-checks occlusion and draws synchronously
        // on the main thread, so only a real change is worth it (as
        // AgentTerminalView already does).
        if container.isActive != isActive {
            container.isActive = isActive
            container.terminal?.setActive(isActive)
        }
        if container.fontSize != fontSize {
            container.fontSize = fontSize
            container.terminal?.setFontSize(fontSize)
        }
    }

    // updateUIView runs inside SwiftUI's update pass; publishing a grid
    // synchronously from there would mutate view state mid-update
    // (undefined behavior). One hop to the next main-actor turn keeps the
    // readout update ordered and legal.
    private var gridConsumer: @MainActor (TerminalGridSize) -> Void {
        let onGrid = onGrid
        return { grid in
            Task { @MainActor in
                onGrid(grid)
            }
        }
    }

    static func dismantleUIView(_ container: PreviewContainer, coordinator: Void) {
        container.terminal?.shutdown()
        container.terminal?.removeFromSuperview()
        container.terminal = nil
    }

    @MainActor
    final class PreviewContainer: UIView {
        fileprivate var terminal: GhosttyTerminalSurfaceView?
        // What was last applied, so an update pass that changed neither
        // touches the surface.
        fileprivate var isActive: Bool?
        fileprivate var fontSize: Double?
    }
}
