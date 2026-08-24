import Foundation
import Observation
import os

struct AgentSummary: Identifiable, Equatable, Sendable, Decodable {
    let id: String
    let agent: String
    let status: String
    let cwd: String
    let title: String
    let workspaceId: String
    let tabId: String
    let focused: Bool
}

private struct AgentsSnapshotMessage: Decodable {
    let type: String
    let available: Bool
    let reason: String?
    let agents: [AgentSummary]
}

// Live mirror of the host's /api/events feed: a full agents snapshot on
// connect and on every change. State is exactly what the host pushed —
// never inferred client-side.
@MainActor
@Observable
final class AgentDirectory {
    private static let logger = Logger(subsystem: "com.parvezrob.mocha", category: "agents.directory")
    private static let eventsProtocol = "mocha.events.v1"
    private static let retryDelay: Duration = .seconds(2)

    private(set) var agents: [AgentSummary] = []
    private(set) var available = false
    private(set) var reason: String?
    private(set) var isRunning = false

    private var credential = ""
    private var host: HostEndpoint?
    private var streamTask: Task<Void, Never>?

    func configure(hostText: String, credential: String) {
        stop()
        guard let url = URL(string: hostText),
              let endpoint = try? HostEndpoint(baseURL: url),
              !credential.isEmpty else {
            host = nil
            self.credential = ""
            return
        }
        host = endpoint
        self.credential = credential
        start()
    }

    func start() {
        guard streamTask == nil, let host, !credential.isEmpty else { return }
        guard let eventsURL = try? host.eventsURL() else { return }
        isRunning = true
        let credential = credential
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.streamOnce(eventsURL: eventsURL, credential: credential)
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: Self.retryDelay)
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isRunning = false
    }

    var isConfigured: Bool {
        host != nil && !credential.isEmpty
    }

    // Creates a Herdr tab (optionally launching an agent in it). The new
    // agent then arrives through the live snapshot feed like any other.
    func createTab(agent: String?) async -> String? {
        guard let host, !credential.isEmpty else { return "Connect a host first." }
        guard var components = URLComponents(url: host.baseURL, resolvingAgainstBaseURL: false) else {
            return "The host address is invalid."
        }
        components.path = "/api/herdr/tabs"
        guard let url = components.url else { return "The host address is invalid." }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = agent.map { ["agent": $0] } ?? [:]
        request.httpBody = try? JSONEncoder().encode(body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                return "The host did not answer."
            }
            guard status == 201 else {
                let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                return message ?? "The host could not create the tab (HTTP \(status))."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func streamOnce(eventsURL: URL, credential: String) async {
        var request = URLRequest(url: eventsURL)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.eventsProtocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        do {
            while !Task.isCancelled {
                let frame = try await socket.receive()
                guard case let .string(text) = frame else { continue }
                let snapshot = try JSONDecoder().decode(AgentsSnapshotMessage.self, from: Data(text.utf8))
                guard snapshot.type == "agents" else { continue }
                agents = snapshot.agents
                available = snapshot.available
                reason = snapshot.reason
            }
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.info("events stream ended: \(error.localizedDescription)")
            if available {
                available = false
                reason = "Reconnecting to the host."
            }
        }
    }
}
