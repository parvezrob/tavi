import Foundation

@MainActor
final class TerminalIOBridge {
    typealias DataConsumer = @MainActor (Data) -> Void
    // True means the bytes are in a live surface's ordered delivery queue;
    // false means nothing took them (#108).
    typealias OutputConsumer = @MainActor (Data) -> Bool
    typealias ActionConsumer = @MainActor () -> Void
    typealias RendererConsumer = @MainActor (RendererChange) -> Void

    // Which surface a renderer callback belongs to: a surface outlives both
    // its replacement's install and its session's end, and what it says in
    // between belongs to nobody. The counter never resets.
    struct RendererToken: Equatable {
        fileprivate let value: Int
    }

    // Every one of these ends the resume epoch except `attached`.
    enum RendererChange: Sendable {
        case attached
        case detached
        // Bytes were dropped before any surface took them; only a fresh
        // attach can put the screen right again.
        case outputDiscarded
    }

    private static let maximumPendingOutputBytes = 1_048_576

    private var inputConsumer: DataConsumer?
    private var outputConsumer: OutputConsumer?
    private var focusConsumer: ActionConsumer?
    private var dismissKeyboardConsumer: ActionConsumer?
    private var rendererConsumer: RendererConsumer?
    private var rendererToken: RendererToken?
    private var issuedRendererTokens = 0
    private var session = 0
    private var pendingOutput = Data()

    var hasRenderer: Bool { outputConsumer != nil }

    // Reads the token at call time: makeUIView wires a surface's callbacks
    // before the bridge has issued its token, and Ghostty drains batched
    // keystrokes on a later turn, possibly after the pane has changed.
    func whileCurrentRenderer<Value>(
        token: @escaping @MainActor () -> RendererToken?,
        _ body: @escaping @MainActor (Value) -> Void
    ) -> @MainActor (Value) -> Void {
        { [weak self] value in
            guard let self, let token = token(), rendererToken == token else { return }
            body(value)
        }
    }

    // A deliberate attach, possibly to another pane than the surface shows.
    // The old surface stops being the renderer and its held bytes go; the
    // view recreates the surface because it is keyed to the session. No
    // `.detached` follows, because pausing would cancel the dial the caller
    // is about to make.
    func beginSession(_ id: Int) {
        guard id != session else { return }
        session = id
        releaseRendererState()
    }

    func discardPendingOutput() {
        pendingOutput.removeAll(keepingCapacity: false)
    }

    func installInputConsumer(_ consumer: @escaping DataConsumer) {
        inputConsumer = consumer
    }

    func removeInputConsumer() {
        inputConsumer = nil
    }

    func installRendererConsumer(_ consumer: @escaping RendererConsumer) {
        rendererConsumer = consumer
    }

    func installTerminal(
        outputConsumer: @escaping OutputConsumer,
        focusConsumer: @escaping ActionConsumer,
        dismissKeyboardConsumer: @escaping ActionConsumer
    ) -> RendererToken {
        // Installing over a live surface is that surface's ending, whether
        // or not its own removal ever arrives.
        if self.outputConsumer != nil {
            releaseRenderer()
        }
        issuedRendererTokens += 1
        let token = RendererToken(value: issuedRendererTokens)
        rendererToken = token
        self.outputConsumer = outputConsumer
        self.focusConsumer = focusConsumer
        self.dismissKeyboardConsumer = dismissKeyboardConsumer
        rendererConsumer?(.attached)

        guard !pendingOutput.isEmpty else { return token }
        let output = pendingOutput
        pendingOutput.removeAll(keepingCapacity: false)
        if !outputConsumer(output) {
            rendererConsumer?(.outputDiscarded)
        }
        return token
    }

    func removeTerminal(_ token: RendererToken) {
        guard rendererToken == token else { return }
        releaseRenderer()
    }

    func focusTerminal() {
        focusConsumer?()
    }

    func dismissKeyboard() {
        dismissKeyboardConsumer?()
    }

    // False is a discard: the caller must not acknowledge these bytes to
    // the host.
    @discardableResult
    func receiveRemoteOutput(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        if let outputConsumer {
            guard outputConsumer(data) else {
                rendererConsumer?(.outputDiscarded)
                return false
            }
            return true
        }

        pendingOutput.append(data)
        guard pendingOutput.count > Self.maximumPendingOutputBytes else { return true }
        // The whole queue goes, not the oldest of it: a trimmed suffix would
        // paint a screen with a hole in it.
        pendingOutput.removeAll(keepingCapacity: false)
        rendererConsumer?(.outputDiscarded)
        return false
    }

    func receiveTerminalInput(_ data: Data) {
        guard !data.isEmpty else { return }
        inputConsumer?(data)
    }

    private func releaseRenderer() {
        releaseRendererState()
        rendererConsumer?(.detached)
    }

    private func releaseRendererState() {
        rendererToken = nil
        outputConsumer = nil
        focusConsumer = nil
        dismissKeyboardConsumer = nil
        // The next surface starts from a repaint, never from another pane's tail.
        pendingOutput.removeAll(keepingCapacity: false)
    }
}
