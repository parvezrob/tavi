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

// Workspace → tab → agents hierarchy from GET /api/herdr/tree, shown in
// the terminal's Jump-to sheet. Agents reuse AgentSummary so the sheet
// speaks the same identity language as the home.
struct HerdrTreeTab: Identifiable, Equatable, Decodable {
    let tabId: String
    let label: String
    let focused: Bool
    let agents: [AgentSummary]

    var id: String { tabId }
}

struct HerdrTreeWorkspace: Identifiable, Equatable, Decodable {
    let workspaceId: String
    let label: String
    let focused: Bool
    let tabs: [HerdrTreeTab]

    var id: String { workspaceId }
}

enum HerdrTreeFetch: Equatable {
    case tree([HerdrTreeWorkspace])
    case failure(String)
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
    // Safe, sanitized terminal excerpts keyed by pane id, refreshed after
    // every snapshot for the agents the home actually previews.
    private(set) var previews: [String: String] = [:]
    // When this phone last saw the agent's status change. Honest client-side
    // freshness: after a reconnect the clock restarts at the replayed
    // snapshot, so it never claims more history than the phone witnessed.
    private(set) var statusObservedAt: [String: Date] = [:]

    private var credential = ""
    private var host: HostEndpoint?
    private var streamTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

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
        previewTask?.cancel()
        previewTask = nil
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

    // Deliberate composer send for an agent target via the host's prompt
    // endpoint. Submits exactly once; returns a user-facing error message
    // on failure, nil on success. Note the host-side contract: the text
    // appends to whatever is already typed in the agent's own composer.
    func promptAgent(paneId: String, text: String) async -> String? {
        guard let host, !credential.isEmpty else { return "Connect a host first." }
        guard var components = URLComponents(url: host.baseURL, resolvingAgainstBaseURL: false) else {
            return "The host address is invalid."
        }
        components.path = "/api/agents/\(paneId)/prompt"
        guard let url = components.url else { return "The host address is invalid." }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["text": text])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                return "The host did not answer."
            }
            guard status == 200 || status == 202 || status == 204 else {
                let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                return message ?? "The host could not deliver the prompt (HTTP \(status))."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func fetchTree() async -> HerdrTreeFetch {
        guard let host, !credential.isEmpty else {
            return .failure("Connect a host first.")
        }
        guard var components = URLComponents(url: host.baseURL, resolvingAgainstBaseURL: false) else {
            return .failure("The host address is invalid.")
        }
        components.path = "/api/herdr/tree"
        guard let url = components.url else { return .failure("The host address is invalid.") }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                return .failure("The host did not answer.")
            }
            guard status == 200 else {
                let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                return .failure(message ?? "The host could not list the workspaces (HTTP \(status)).")
            }
            let payload = try JSONDecoder().decode(TreeResponse.self, from: data)
            return .tree(payload.workspaces)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private struct TreeResponse: Decodable {
        let workspaces: [HerdrTreeWorkspace]
    }

    private func apply(_ snapshot: AgentsSnapshotMessage) {
        let now = Date()
        let previousStatus = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.status) })
        var observed: [String: Date] = [:]
        for agent in snapshot.agents {
            observed[agent.id] = previousStatus[agent.id] == agent.status
                ? statusObservedAt[agent.id] ?? now
                : now
        }
        statusObservedAt = observed
        agents = snapshot.agents
        available = snapshot.available
        reason = snapshot.reason
        previews = previews.filter { key, _ in observed[key] != nil }
        schedulePreviewRefresh()
    }

    // Previews are fetched only for the agents the home shows in full cards
    // (needs-you and active); the short debounce coalesces snapshot bursts.
    private func schedulePreviewRefresh() {
        previewTask?.cancel()
        let targets = agents.filter { $0.homeSection != .recent }.map(\.id)
        guard !targets.isEmpty, host != nil, !credential.isEmpty else { return }
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.refreshPreviews(paneIds: targets)
        }
    }

    private func refreshPreviews(paneIds: [String]) async {
        for paneId in paneIds {
            guard !Task.isCancelled else { return }
            guard let raw = await fetchPreview(paneId: paneId) else { continue }
            previews[paneId] = AgentPreviewFormatter.sanitize(raw)
        }
    }

    private func fetchPreview(paneId: String) async -> String? {
        guard let host,
              var components = URLComponents(url: host.baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/api/agents/\(paneId)/preview"
        components.queryItems = [URLQueryItem(name: "lines", value: "6")]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONDecoder().decode(PreviewResponse.self, from: data) else {
            return nil
        }
        return payload.preview
    }

    private struct PreviewResponse: Decodable {
        let preview: String
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
                apply(snapshot)
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
