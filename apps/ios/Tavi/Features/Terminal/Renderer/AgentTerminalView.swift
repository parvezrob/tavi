import SwiftUI

struct AgentTerminalView: UIViewRepresentable {
    let bridge: TerminalIOBridge
    let isActive: Bool
    let onGridSizeChange: @MainActor (TerminalGridSize) -> Void
    let onRendererReady: @MainActor () -> Void
    let onRendererFailure: @MainActor (String) -> Void
    var onTranscript: (@MainActor (String) -> Void)? = nil

    func makeUIView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        do {
            let runtime = try GhosttyRuntime.shared.get()
            let terminal = try GhosttyTerminalSurfaceView(
                runtime: runtime,
                fontSize: TerminalFontPreference.current(),
                onInput: owned(container) { data in bridge.receiveTerminalInput(data) },
                onFailure: owned(container, onRendererFailure)
            )
            terminal.onGridSizeChange = owned(container, onGridSizeChange)
            terminal.onTranscript = onTranscript.map { owned(container, $0) }
            terminal.recordsViewport = true
            terminal.onFontSizeCommit = { size in
                TerminalFontPreference.save(size)
            }
            container.install(terminal)
            container.rendererToken = bridge.installTerminal(
                outputConsumer: { [weak terminal] data in
                    // A surface that has gone accepts nothing; saying so is
                    // what keeps the host's resume offset honest (#108).
                    terminal?.receive(data) ?? false
                },
                focusConsumer: { [weak terminal] in
                    terminal?.focusKeyboard()
                },
                dismissKeyboardConsumer: { [weak terminal] in
                    terminal?.dismissKeyboard()
                }
            )
            container.bridgeCleanup = { [weak bridge, weak container] in
                guard let token = container?.rendererToken else { return }
                bridge?.removeTerminal(token)
            }
            terminal.setActive(isActive)
            container.isActive = isActive
            // Runs on the install's own turn, so it is current by
            // construction and needs no token of its own.
            onRendererReady()
        } catch {
            onRendererFailure("The terminal renderer could not start.")
        }
        return container
    }

    func updateUIView(_ container: TerminalContainerView, context: Context) {
        container.terminal?.onGridSizeChange = owned(container, onGridSizeChange)
        // setActive re-focuses, re-checks occlusion and draws synchronously
        // on the main thread, so only a real change is worth it.
        guard container.isActive != isActive else { return }
        container.isActive = isActive
        container.terminal?.setActive(isActive)
    }

    static func dismantleUIView(_ container: TerminalContainerView, coordinator: Void) {
        // Cleanup first: shutdown() drops whatever the pump still holds, so
        // the bridge has to have ended this surface's epoch before then.
        container.bridgeCleanup?()
        container.terminal?.shutdown()
        container.terminal?.removeFromSuperview()
        container.terminal = nil
    }

    // A surface outlives both its replacement's install and its session's
    // end, and can still finish work it began: a grid publication, a
    // transcript pass, an overflow report, a keystroke Ghostty batched
    // before the pane changed. None of it belongs to whatever is installed
    // now (#108).
    private func owned<Value>(
        _ container: TerminalContainerView,
        _ body: @escaping @MainActor (Value) -> Void
    ) -> @MainActor (Value) -> Void {
        bridge.whileCurrentRenderer(token: { [weak container] in container?.rendererToken }, body)
    }

    @MainActor
    final class TerminalContainerView: UIView {
        fileprivate var bridgeCleanup: (() -> Void)?
        fileprivate var isActive: Bool?
        // This surface's place in the bridge's succession of renderers.
        fileprivate var rendererToken: TerminalIOBridge.RendererToken?
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
