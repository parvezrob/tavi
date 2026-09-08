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
    // When the peer last delivered a frame (text, binary, ping, pong) — the
    // clock that says whether a stream was ever alive, which `lastActivity`
    // cannot, since the completion that ends a socket moves it too (#111).
    var lastFrameAt: ContinuousClock.Instant { get }

    func resume()
    func receive() async throws -> URLSessionWebSocketTask.Message
    // The payload comes back on the pong, so a challenge can tell its own
    // answer from a late one; a 0.1.17 host echoes it from `ws`'s auto pong.
    func ping(payload: Data) async throws
    func onPong(_ handler: @escaping @Sendable (Data) -> Void)
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension NetworkWebSocketTask: HostEventsSocketing {}
