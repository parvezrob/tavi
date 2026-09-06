import Foundation

// The frame the events stream carries, and the socket seam the link opens
// it on — the same seam the terminal transport has for NetworkWebSocketTask
// (#70, #99).
struct AgentsSnapshotMessage: Decodable {
    let type: String
    let available: Bool
    let reason: String?
    let agents: [AgentSummary]
}

protocol HostEventsSocketing: AnyObject, Sendable {
    // When the last frame of any kind arrived — the watchdog's idle clock.
    var lastActivity: ContinuousClock.Instant { get }

    func resume()
    func receive() async throws -> URLSessionWebSocketTask.Message
    func ping() async throws
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension NetworkWebSocketTask: HostEventsSocketing {}
