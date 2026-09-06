import Foundation
@testable import Tavi
import Testing

// A renderer the test owns. It installs into the real bridge exactly as the
// Ghostty surface does — one output consumer, one token — records what it
// accepted, and can refuse, which is the one thing a surface that has been
// shut down does and the existence of a closure cannot express.
@MainActor
final class SyntheticRenderer {
    private(set) var accepted = Data()
    private(set) var token: TerminalIOBridge.RendererToken?
    // Set false to stand for a surface whose pump is already gone.
    var accepts = true

    var acceptedText: String { String(bytes: accepted, encoding: .utf8) ?? "" }

    func install(into bridge: TerminalIOBridge) {
        token = bridge.installTerminal(
            outputConsumer: { [weak self] data in
                guard let self, accepts else { return false }
                accepted.append(data)
                return true
            },
            focusConsumer: {},
            dismissKeyboardConsumer: {}
        )
    }

    // What dismantleUIView does, with whichever token this renderer was
    // given — stale or current.
    func remove(from bridge: TerminalIOBridge) {
        guard let token else { return }
        bridge.removeTerminal(token)
    }
}
