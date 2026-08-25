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

// A parsed Claude permission/confirm dialog surfaced on a waiting agent's
// pane (#23). Mirrors the host's GET /api/agents/{pane}/dialog shape.
struct PermissionDialogOption: Identifiable, Equatable, Decodable {
    let index: Int
    let label: String
    let selected: Bool

    var id: Int { index }
}

struct PermissionDialog: Equatable, Decodable {
    let prompt: String
    let options: [PermissionDialogOption]
}

private struct DialogResponse: Decodable {
    let present: Bool
    let dialog: PermissionDialog?
}

enum DialogFetch: Equatable {
    case dialog(PermissionDialog)
    case none
    case failure(String)
}

enum DialogDecision: String {
    case approve
    case deny
}

enum DecisionOutcome: Equatable {
    case ok
    // The dialog resolved before the decision landed — nothing was sent.
    case stale
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

    // Every request here carries the bearer token, so it uses the same
    // no-disk-trace policy as the terminal transport (#36): ephemeral
    // storage, no cache, and no silent parking on a dead network path.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private(set) var agents: [AgentSummary] = []
    private(set) var available = false
    private(set) var reason: String?
    private(set) var isRunning = false
    // True after the first snapshot ever arrives; before that an empty list
    // means "still loading", not "no agents".
    private(set) var hasLoaded = false
    // The stream is down and `agents` is the last known state (PRD §7.8:
    // resume with an explicit stale indicator, never a blank screen). A
    // blocked agent therefore stays visible through reconnects until a live
    // snapshot actually reports it resolved.
    private(set) var isStale = false
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
    private let smoother = AgentStatusSmoother()
    // Raw agents from the latest snapshot, re-presented when a pending
    // status de-escalation matures without a new snapshot arriving.
    private var lastRawAgents: [AgentSummary] = []
    private var reviewTask: Task<Void, Never>?

    func configure(hostText: String, credential: String) {
        stop()
        // A different host is a different world: never show one host's
        // agents as another's "last known state".
        agents = []
        previews = [:]
        statusObservedAt = [:]
        available = false
        reason = nil
        hasLoaded = false
        isStale = false
        lastRawAgents = []
        smoother.reset()
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
        reviewTask?.cancel()
        reviewTask = nil
        isRunning = false
        // Whatever we show next launch/foreground is last-known until the
        // stream confirms otherwise.
        if hasLoaded { isStale = true }
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
            let (data, response) = try await Self.session.data(for: request)
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

    // Reads the live permission dialog on a waiting agent's pane (#23) so the
    // Needs-you sheet can show the real choices. `.none` means no dialog is
    // currently rendered (it may have just resolved).
    func fetchDialog(paneId: String) async -> DialogFetch {
        guard let host, !credential.isEmpty else { return .failure("Connect a host first.") }
        guard var components = URLComponents(url: host.baseURL, resolvingAgainstBaseURL: false) else {
            return .failure("The host address is invalid.")
        }
        components.path = "/api/agents/\(paneId)/dialog"
        guard let url = components.url else { return .failure("The host address is invalid.") }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                return .failure("The host did not answer.")
            }
            guard status == 200 else {
                let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                return .failure(message ?? "The host could not read the dialog (HTTP \(status)).")
            }
            let payload = try JSONDecoder().decode(DialogResponse.self, from: data)
            guard payload.present, let dialog = payload.dialog else { return .none }
            return .dialog(dialog)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // Answers a waiting permission from the phone (#23). The host re-reads the
    // pane and refuses (409) if the dialog is already gone; that surfaces as
    // `.stale` so the sheet can say the wait resolved instead of implying the
    // tap did something. Returns `.ok` on a delivered decision.
    func decide(paneId: String, decision: DialogDecision) async -> DecisionOutcome {
        guard let host, !credential.isEmpty else { return .failure("Connect a host first.") }
        guard var components = URLComponents(url: host.baseURL, resolvingAgainstBaseURL: false) else {
            return .failure("The host address is invalid.")
        }
        components.path = "/api/agents/\(paneId)/decision"
        guard let url = components.url else { return .failure("The host address is invalid.") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["decision": decision.rawValue])

        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                return .failure("The host did not answer.")
            }
            if status == 200 { return .ok }
            if status == 409 { return .stale }
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            return .failure(message ?? "The host could not deliver the decision (HTTP \(status)).")
        } catch {
            return .failure(error.localizedDescription)
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
            let (data, response) = try await Self.session.data(for: request)
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
            let (data, response) = try await Self.session.data(for: request)
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
        available = snapshot.available
        reason = snapshot.reason
        hasLoaded = true
        isStale = false
        lastRawAgents = snapshot.agents
        present(lastRawAgents)
    }

    private func present(_ rawAgents: [AgentSummary]) {
        let now = Date()
        let (smoothed, nextReview) = smoother.apply(rawAgents, now: now)

        let previousStatus = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.status) })
        var observed: [String: Date] = [:]
        for agent in smoothed {
            observed[agent.id] = previousStatus[agent.id] == agent.status
                ? statusObservedAt[agent.id] ?? now
                : now
        }
        statusObservedAt = observed
        agents = smoothed
        previews = previews.filter { key, _ in observed[key] != nil }
        schedulePreviewRefresh()

        reviewTask?.cancel()
        reviewTask = nil
        if let nextReview {
            let delay = max(0.1, nextReview.timeIntervalSince(now))
            reviewTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.present(self.lastRawAgents)
            }
        }
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
        guard let (data, response) = try? await Self.session.data(for: request),
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
        let socket = Self.session.webSocketTask(with: request)
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
            // Keep the last known agents on screen, explicitly stale —
            // dropping them here made "Needs you" blink away on every
            // network blip while the agent was still waiting.
            isStale = true
        }
    }
}
