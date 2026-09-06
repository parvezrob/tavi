import Foundation

// The two pieces of behaviour the soak needs beside the contract (#111): the
// history the phone cannot keep, and the second client that makes a takeover
// a takeover.

// The complete history the phone cannot keep: every ring event this run ever
// saw, merged by the monotonic timestamp the phone stamped it with.
final class RingCollector {
    private(set) var events: [DiagnosticsEvent] = []
    private var seen: Set<String> = []

    func merge(_ line: DiagnosticsLine) {
        for event in line.ring where seen.insert("\(event.source)|\(event.monotonic)|\(event.kind)|\(event.reason)").inserted {
            events.append(event)
        }
        events.sort { $0.monotonic < $1.monotonic }
    }

    func first(_ source: String, _ kind: String, after at: Double) -> DiagnosticsEvent? {
        events.first { $0.source == source && $0.kind == kind && Double($0.at) > at }
    }

    func all(_ source: String, _ kind: String, from: Double, to: Double) -> [DiagnosticsEvent] {
        events.filter { $0.source == source && $0.kind == kind && Double($0.at) > from && Double($0.at) <= to }
    }
}

// A second real `tavi.v2` client, which is what makes a takeover a takeover.
// It only has to connect without resume parameters and keep draining.
final class TakeoverClient: Sendable {
    private let task: URLSessionWebSocketTask

    init?(host: String, token: String, paneId: String) {
        guard let url = URL(string: "\(host)/api/agents/\(paneId)/terminal")?.wsScheme else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("tavi.v2", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        task = URLSession.shared.webSocketTask(with: request)
    }

    func start() {
        task.resume()
        drain()
    }

    func stop() { task.cancel(with: .goingAway, reason: nil) }

    private func drain() {
        task.receive { [weak self] result in
            guard case .success = result else { return }
            self?.drain()
        }
    }
}

extension URL {
    var wsScheme: URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        return components.url
    }
}
