import Foundation

@MainActor
final class TerminalIOBridge {
    typealias DataConsumer = @MainActor (Data) -> Void
    typealias ActionConsumer = @MainActor () -> Void

    private static let maximumPendingOutputBytes = 1_048_576

    private var inputConsumer: DataConsumer?
    private var outputConsumer: DataConsumer?
    private var focusConsumer: ActionConsumer?
    private var dismissKeyboardConsumer: ActionConsumer?
    private var pendingOutput = Data()

    func installInputConsumer(_ consumer: @escaping DataConsumer) {
        inputConsumer = consumer
    }

    func removeInputConsumer() {
        inputConsumer = nil
    }

    func installTerminal(
        outputConsumer: @escaping DataConsumer,
        focusConsumer: @escaping ActionConsumer,
        dismissKeyboardConsumer: @escaping ActionConsumer
    ) {
        self.outputConsumer = outputConsumer
        self.focusConsumer = focusConsumer
        self.dismissKeyboardConsumer = dismissKeyboardConsumer

        guard !pendingOutput.isEmpty else { return }
        let output = pendingOutput
        pendingOutput.removeAll(keepingCapacity: true)
        outputConsumer(output)
    }

    func removeTerminal() {
        outputConsumer = nil
        focusConsumer = nil
        dismissKeyboardConsumer = nil
    }

    func focusTerminal() {
        focusConsumer?()
    }

    func dismissKeyboard() {
        dismissKeyboardConsumer?()
    }

    func receiveRemoteOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        if let outputConsumer {
            outputConsumer(data)
            return
        }

        pendingOutput.append(data)
        if pendingOutput.count > Self.maximumPendingOutputBytes {
            pendingOutput.removeFirst(pendingOutput.count - Self.maximumPendingOutputBytes)
        }
    }

    func receiveTerminalInput(_ data: Data) {
        guard !data.isEmpty else { return }
        inputConsumer?(data)
    }
}
