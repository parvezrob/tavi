import Foundation

struct TerminalInputDelivery: Sendable {
    let sender: any TerminalMessageSending

    func submitOnce(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        let value = String(decoding: data, as: UTF8.self)
        try await sender.send(.input(value))
    }
}
