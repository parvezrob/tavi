import SwiftUI

struct AgentTerminalView: UIViewRepresentable {
    let bridge: TerminalIOBridge
    let isActive: Bool
    let onGridSizeChange: @MainActor (TerminalGridSize) -> Void
    let onRendererReady: @MainActor () -> Void
    let onRendererFailure: @MainActor (String) -> Void

    func makeUIView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        do {
            let runtime = try GhosttyRuntime.shared.get()
            let terminal = try GhosttyTerminalSurfaceView(
                runtime: runtime,
                fontSize: TerminalFontPreference.current(),
                onInput: { data in bridge.receiveTerminalInput(data) },
                onFailure: onRendererFailure
            )
            terminal.onGridSizeChange = onGridSizeChange
            terminal.recordsViewport = true
            terminal.onFontSizeCommit = { size in
                TerminalFontPreference.save(size)
            }
            container.install(terminal)
            bridge.installTerminal(
                outputConsumer: { [weak terminal] data in
                    terminal?.receive(data)
                },
                focusConsumer: { [weak terminal] in
                    terminal?.focusKeyboard()
                },
                dismissKeyboardConsumer: { [weak terminal] in
                    terminal?.dismissKeyboard()
                }
            )
            container.bridgeCleanup = { [weak bridge] in
                bridge?.removeTerminal()
            }
            terminal.setActive(isActive)
            onRendererReady()
        } catch {
            onRendererFailure("The terminal renderer could not start.")
        }
        return container
    }

    func updateUIView(_ container: TerminalContainerView, context: Context) {
        container.terminal?.onGridSizeChange = onGridSizeChange
        container.terminal?.setActive(isActive)
    }

    static func dismantleUIView(_ container: TerminalContainerView, coordinator: Void) {
        container.bridgeCleanup?()
        container.terminal?.shutdown()
        container.terminal?.removeFromSuperview()
        container.terminal = nil
    }

    @MainActor
    final class TerminalContainerView: UIView {
        fileprivate var bridgeCleanup: (() -> Void)?
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
