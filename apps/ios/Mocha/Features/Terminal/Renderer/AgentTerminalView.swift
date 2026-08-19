import SwiftUI

struct AgentTerminalView: UIViewRepresentable {
    let bridge: TerminalIOBridge
    let isActive: Bool
    let onGridSizeChange: @MainActor (TerminalGridSize) -> Void
    let onRendererFailure: @MainActor (String) -> Void

    func makeUIView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        do {
            let runtime = try GhosttyRuntime.shared.get()
            let terminal = try GhosttyTerminalSurfaceView(
                runtime: runtime,
                onInput: { data in bridge.receiveTerminalInput(data) },
                onFailure: onRendererFailure
            )
            terminal.onGridSizeChange = onGridSizeChange
            container.install(terminal)
            bridge.installTerminal { [weak terminal] data in
                terminal?.receive(data)
            }
            container.bridgeCleanup = { [weak bridge] in
                bridge?.removeTerminal()
            }
            terminal.setActive(isActive)
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
