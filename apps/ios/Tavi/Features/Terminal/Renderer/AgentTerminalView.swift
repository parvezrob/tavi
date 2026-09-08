import SwiftUI

struct AgentTerminalView: UIViewRepresentable {
    let bridge: TerminalIOBridge
    // The surface that belongs to this pane, kept across the container
    // rebuilds SwiftUI makes on its own (#111).
    let surfaces: TerminalSurfaceOwner
    let sessionID: Int
    let isActive: Bool
    let onGridSizeChange: @MainActor (TerminalGridSize) -> Void
    let onRendererReady: @MainActor () -> Void
    let onRendererFailure: @MainActor (String) -> Void
    var onTranscript: (@MainActor (String) -> Void)? = nil

    func makeUIView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.surfaces = surfaces
        if let terminal = surfaces.reusableSurface(for: sessionID) {
            // The same pane's own surface, moved into the container SwiftUI
            // has just built. The bridge is told nothing, because from the
            // session's side nothing happened.
            bind(terminal)
            container.install(terminal)
            surfaces.setActive(isActive)
            return container
        }
        do {
            let runtime = try GhosttyRuntime.shared.get()
            let terminal = try GhosttyTerminalSurfaceView(
                runtime: runtime,
                fontSize: TerminalFontPreference.current(),
                onInput: owned { data in bridge.receiveTerminalInput(data) },
                onFailure: owned(onRendererFailure)
            )
            bind(terminal)
            terminal.recordsViewport = true
            terminal.onFontSizeCommit = { size in
                TerminalFontPreference.save(size)
            }
            container.install(terminal)
            let token = bridge.installTerminal(
                outputConsumer: { [weak terminal] data in
                    // A surface that has gone accepts nothing (#108).
                    terminal?.receive(data) ?? false
                },
                focusConsumer: { [weak terminal] in
                    terminal?.focusKeyboard()
                },
                dismissKeyboardConsumer: { [weak terminal] in
                    terminal?.dismissKeyboard()
                }
            )
            surfaces.adopt(terminal, token: token, sessionID: sessionID)
            surfaces.setActive(isActive)
            onRendererReady()
        } catch {
            onRendererFailure("The terminal renderer could not start.")
        }
        return container
    }

    func updateUIView(_ container: TerminalContainerView, context: Context) {
        container.terminal?.onGridSizeChange = owned(onGridSizeChange)
        surfaces.setActive(isActive)
    }

    static func dismantleUIView(_ container: TerminalContainerView, coordinator: Void) {
        // The surface stays: whether this was a rebuild or the screen leaving
        // is decided a turn later, by whether anything adopted it.
        if let terminal = container.terminal, terminal.superview === container {
            terminal.removeFromSuperview()
        }
        container.terminal = nil
        container.surfaces?.containerWentAway()
    }

    private func bind(_ terminal: GhosttyTerminalSurfaceView) {
        terminal.onGridSizeChange = owned(onGridSizeChange)
        terminal.onTranscript = onTranscript.map { owned($0) }
    }

    // A surface outlives its replacement's install and its session's end,
    // and can still finish work it began (a grid publication, a batched
    // keystroke). None of it belongs to whatever is installed now (#108).
    private func owned<Value>(
        _ body: @escaping @MainActor (Value) -> Void
    ) -> @MainActor (Value) -> Void {
        bridge.whileCurrentRenderer(token: { [weak surfaces] in surfaces?.token }, body)
    }

    @MainActor
    final class TerminalContainerView: UIView {
        fileprivate var surfaces: TerminalSurfaceOwner?
        fileprivate var terminal: GhosttyTerminalSurfaceView?

        func install(_ terminal: GhosttyTerminalSurfaceView) {
            self.terminal = terminal
            addSubview(terminal)
            terminal.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
                terminal.topAnchor.constraint(equalTo: topAnchor),
                terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }
}
