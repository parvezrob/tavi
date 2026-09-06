import Foundation

@MainActor
final class TerminalIOBridge {
    typealias DataConsumer = @MainActor (Data) -> Void
    // Output is the one direction with an answer: true means the bytes are
    // in the ordered delivery queue of a live surface, false means nothing
    // took them (#108).
    typealias OutputConsumer = @MainActor (Data) -> Bool
    typealias ActionConsumer = @MainActor () -> Void
    typealias RendererConsumer = @MainActor (RendererChange) -> Void

    // Which surface a renderer callback belongs to. A surface outlives both
    // its replacement's install and its own session's end, and everything it
    // says or is asked in between belongs to nobody. The counter behind it
    // never resets, so no two surfaces of this bridge share a token.
    struct RendererToken: Equatable {
        fileprivate let value: Int
    }

    // What the session controller has to know about the screen the bytes are
    // going to. Every one of these ends the resume epoch except `attached`.
    enum RendererChange: Sendable {
        case attached
        case detached
        // Bytes the host had sent were dropped before any surface took
        // them: only a fresh attach can put the screen right again.
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

    // Every callback a surface makes goes through this, and reads its token
    // at call time: makeUIView wires a surface's callbacks before the bridge
    // has a token to give it, and Ghostty drains batched keystrokes on a
    // later main-actor turn — possibly after the pane has changed.
    func whileCurrentRenderer<Value>(
        token: @escaping @MainActor () -> RendererToken?,
        _ body: @escaping @MainActor (Value) -> Void
    ) -> @MainActor (Value) -> Void {
        { [weak self] value in
            guard let self, let token = token(), rendererToken == token else { return }
            body(value)
        }
    }

    // A deliberate attach to a pane, which may not be the pane the surface
    // on screen is showing. Bytes held for the old one are dropped and its
    // surface stops being the installed renderer; the view recreates the
    // renderer because it is keyed to this session. No `.detached` follows:
    // the caller is establishing the session this is part of, and pausing it
    // mid-connect would cancel the dial it is about to make.
    func beginSession(_ id: Int) {
        guard id != session else { return }
        session = id
        releaseRendererState()
    }

    // A session that is over keeps nothing for a surface that may still
    // attach: those bytes belong to a stream nobody can resume.
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
        // or not its own removal ever arrives: the bytes it accepted went
        // with it. The replacement is told so before it is handed anything.
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

    // True when every byte is now in the surface's delivery queue, or is
    // held for the surface that has not attached yet. False is a discard:
    // the caller must not acknowledge these bytes to the host.
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
        // paint a screen with a hole in it and call the result live.
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
        // Bytes held for a surface belong to that surface alone; the next
        // one starts from a repaint, never from another pane's tail.
        pendingOutput.removeAll(keepingCapacity: false)
    }
}
