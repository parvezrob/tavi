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
    // The herdr tab's label (#55) — the user's own name for the task when
    // they set one. Absent from older hosts; presentation decides which
    // labels are user-meaningful.
    var tabLabel: String? = nil
    let focused: Bool
    // The paired computer this agent runs on (#50). Not part of the wire
    // shape — a host does not know how the phone names it — so the
    // directory stamps it on every agent it presents. A pane id alone is
    // no longer unique across the home: every target is host + pane.
    var hostId: String = ""

    private enum CodingKeys: String, CodingKey {
        case id, agent, status, cwd, title, workspaceId, tabId, tabLabel, focused
    }
}

// How the phone is doing against one paired computer right now (#50).
// Reported per host so one computer being asleep never hides another.
enum HostHealth: Equatable {
    // No snapshot yet since the stream started.
    case connecting
    // The events stream is up; what is shown is what the host says.
    case live
    // The stream dropped but the host answers: reconnecting, showing the
    // last known state.
    case stale
    // The host itself does not answer (asleep, off the tailnet, or this
    // phone is offline). Last known state stays on screen.
    case offline
    // The host rejected this phone's credential; only pairing again helps.
    case revoked
}

// A folder the New Agent picker can start an agent in (#24). `recent` is the
// host's merge of folders agents are living in now with the choices this host
// remembers; `workspaces` is the browsable scan of the configured roots.
struct ProjectFolder: Identifiable, Equatable, Decodable {
    let path: String
    let name: String
    // An agent is running here right now.
    let active: Bool
    // Inside a project root configured on the Mac. A folder outside them
    // still works, but starting there asks for confirmation first — the
    // picker says so up front instead of surprising you after a tap. The
    // host remains the authority: it makes the same judgement on create.
    let withinRoots: Bool

    var id: String { path }
}

struct ProjectWorkspace: Identifiable, Equatable, Decodable {
    let name: String
    let path: String
    let git: Bool

    var id: String { path }
}

// An agent the host's herdr can launch. `installed` is whether the
// executable resolves on the Mac's login-shell PATH — the picker offers
// every kind so the list is honest about what exists, but only installed
// ones can be chosen.
struct AgentKind: Identifiable, Equatable, Decodable {
    let kind: String
    let label: String
    let installed: Bool

    var id: String { kind }
}

struct ProjectCatalog: Equatable, Decodable {
    let recent: [ProjectFolder]
    let workspaces: [ProjectWorkspace]
    // The project roots configured on the Mac. Empty means none were found,
    // which is worth saying plainly: every folder will then need confirming.
    let roots: [String]
    let agents: [AgentKind]
}

enum ProjectsFetch: Equatable {
    case catalog(ProjectCatalog)
    case failure(String)
}

// Creating an agent always names a folder. The host owns the rule about
// which folders are ordinary and which need a second look, so a location
// outside its configured roots comes back as a confirmation request rather
// than a failure — the phone asks, then retries with the confirmation.
enum CreateAgentOutcome: Equatable {
    case created
    case needsOutsideRootsConfirmation
    case failure(String)
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

// approve = confirm the highlighted option (Enter); deny = cancel (Esc);
// option = pick a specific numbered choice by its index.
enum DialogDecision: Equatable {
    case approve
    case deny
    case option(Int)
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
    private static let logger = Logger(subsystem: "com.farfield.tavi", category: "agents.directory")
    private static let eventsProtocol = "tavi.events.v1"
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
    // The host rejected this phone's credential outright (#46): revoked on
    // the Mac, or the host was reset. Retrying cannot fix it; only pairing
    // again can, so the stream stops and the home says so.
    private(set) var isRevoked = false
    // The host did not answer the last reachability probe (#50). Set only
    // after a stream drop whose follow-up probe timed out or failed at the
    // connection level; cleared by the next live snapshot.
    private(set) var isOffline = false
    // Round trip to an authenticated endpoint, refreshed while the stream
    // is up and on every drop probe. nil until measured.
    private(set) var latencyMilliseconds: Int?
    // Which paired computer this directory mirrors (#50).
    private(set) var hostId = ""
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
    private var latencyTask: Task<Void, Never>?
    private static let latencyInterval: Duration = .seconds(30)

    var health: HostHealth {
        if isRevoked { return .revoked }
        if isOffline { return .offline }
        if !hasLoaded { return .connecting }
        return isStale ? .stale : .live
    }

    func configure(hostId: String, hostText: String, credential: String) {
        stop()
        self.hostId = hostId
        // A different host is a different world: never show one host's
        // agents as another's "last known state".
        agents = []
        previews = [:]
        statusObservedAt = [:]
        available = false
        reason = nil
        hasLoaded = false
        isStale = false
        isRevoked = false
        isOffline = false
        latencyMilliseconds = nil
        lastRawAgents = []
        smoother.reset()
        guard let url = URL(string: hostText),
              let endpoint = try? HostEndpoint(baseURL: url),
              !credential.isEmpty else {
            host = nil
            self.credential = ""
            // Nothing can connect without a credential or a valid address,
            // and "Connecting…" forever would be a fabricated state. Say
            // so with the same offers as a revocation: pair again or remove.
            isRevoked = true
            hasLoaded = true
            available = false
            reason = credential.isEmpty
                ? "Tavi no longer has a credential for this computer. Pair it again to reconnect."
                : "This computer's address is not valid any more. Pair it again to reconnect."
            return
        }
        host = endpoint
        self.credential = credential
        start()
    }

    func start() {
        // A dead credential stays dead: re-dialing it on every foreground
        // would only produce 401s (#46).
        guard streamTask == nil, !isRevoked, let host, !credential.isEmpty else { return }
        guard let eventsURL = try? host.eventsURL() else { return }
        isRunning = true
        // Whether the computer answers is decided by this attempt, not the
        // last one before the app went to the background.
        isOffline = false
        let credential = credential
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.streamOnce(eventsURL: eventsURL, credential: credential)
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: Self.retryDelay)
            }
        }
        latencyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.latencyInterval)
                guard !Task.isCancelled, let self else { return }
                guard self.hasLoaded, !self.isStale else { continue }
                if case let .reachable(latency) = await self.probeHost() {
                    self.latencyMilliseconds = latency
                }
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
        latencyTask?.cancel()
        latencyTask = nil
        isRunning = false
        // Whatever we show next launch/foreground is last-known until the
        // stream confirms otherwise.
        if hasLoaded { isStale = true }
    }

    var isConfigured: Bool {
        host != nil && !credential.isEmpty
    }

    // The folders the New Agent picker offers (#24). One call: recent
    // choices plus the browsable roots, both ordered by the host.
    func fetchProjects() async -> ProjectsFetch {
        guard let host, !credential.isEmpty else { return .failure("Connect a host first.") }
        guard var components = URLComponents(url: host.baseURL, resolvingAgainstBaseURL: false) else {
            return .failure("The host address is invalid.")
        }
        components.path = "/api/projects"
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
                return .failure(message ?? "The host could not list your projects (HTTP \(status)).")
            }
            do {
                return .catalog(try JSONDecoder().decode(ProjectCatalog.self, from: data))
            } catch {
                // A shape this client cannot read is a version mismatch, not
                // a network problem — say which, since retrying never helps.
                return .failure("This host sent a project list Tavi does not understand. Update the Tavi host and the app to matching versions.")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // Creates a Herdr tab in a chosen project folder and launches the agent
    // in it. The new agent then arrives through the live snapshot feed like
    // any other. `allowOutsideRoots` is the phone confirming a location the
    // host flagged as outside its project roots — never sent unprompted.
    func createTab(agent: String?, cwd: String, allowOutsideRoots: Bool = false) async -> CreateAgentOutcome {
        guard let host, !credential.isEmpty else { return .failure("Connect a host first.") }
        guard var components = URLComponents(url: host.baseURL, resolvingAgainstBaseURL: false) else {
            return .failure("The host address is invalid.")
        }
        components.path = "/api/herdr/tabs"
        guard let url = components.url else { return .failure("The host address is invalid.") }

        var body: [String: Any] = ["cwd": cwd]
        if let agent { body["agent"] = agent }
        if allowOutsideRoots { body["allowOutsideRoots"] = true }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                return .failure("The host did not answer.")
            }
            if status == 201 { return .created }
            let failure = try? JSONDecoder().decode(CreateTabFailure.self, from: data)
            if failure?.outsideRoots == true { return .needsOutsideRootsConfirmation }
            return .failure(failure?.error ?? "The host could not create the tab (HTTP \(status)).")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private struct CreateTabFailure: Decodable {
        let error: String?
        let outsideRoots: Bool?
    }

    // Asks the host to revoke this phone's own credential (#46). nil on
    // success; a message when the host could not be reached or refused —
    // the caller then decides whether to forget locally anyway.
    func unpairSelf() async -> String? {
        guard let host, !credential.isEmpty else { return "This iPhone is not paired." }
        guard var components = URLComponents(url: host.baseURL, resolvingAgainstBaseURL: false) else {
            return "The host address is invalid."
        }
        components.path = "/api/devices/me"
        guard let url = components.url else { return "The host address is invalid." }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                return "The computer did not answer."
            }
            // 401 means the credential is already dead: unpaired either way.
            guard status == 204 || status == 401 else {
                let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                return message ?? "The computer could not unpair this iPhone (HTTP \(status))."
            }
            return nil
        } catch {
            return "Could not reach the computer: \(error.localizedDescription)"
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
        request.httpBody = try? JSONSerialization.data(withJSONObject: decisionBody(decision))

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

    private func decisionBody(_ decision: DialogDecision) -> [String: Any] {
        switch decision {
        case .approve: return ["decision": "approve"]
        case .deny: return ["decision": "deny"]
        case let .option(index): return ["decision": "option", "option": index]
        }
    }

    // Deliberate composer send for an agent target via the host's prompt
    // endpoint. Submits exactly once; returns a user-facing error message
    // on failure, nil on success. Note the host-side contract: the text
    // appends to whatever is already typed in the agent's own composer.
    // Renames the herdr tab behind a pane (#55). Returns a user-facing
    // error message, nil on success; the new label reaches every phone
    // through the events feed like any other change.
    func renameTab(tabId: String, label: String) async -> String? {
        guard let host, !credential.isEmpty else { return "Connect a host first." }
        guard var components = URLComponents(url: host.baseURL, resolvingAgainstBaseURL: false) else {
            return "The host address is invalid."
        }
        components.path = "/api/herdr/tabs/\(tabId)"
        guard let url = components.url else { return "The host address is invalid." }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["label": label])

        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                return "The host did not answer."
            }
            guard status == 200 else {
                let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                return message ?? "The host could not rename the tab (HTTP \(status))."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

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
            return .tree(payload.workspaces.map { workspace in
                HerdrTreeWorkspace(
                    workspaceId: workspace.workspaceId,
                    label: workspace.label,
                    focused: workspace.focused,
                    tabs: workspace.tabs.map { tab in
                        HerdrTreeTab(tabId: tab.tabId, label: tab.label, focused: tab.focused, agents: stamped(tab.agents))
                    }
                )
            })
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private struct TreeResponse: Decodable {
        let workspaces: [HerdrTreeWorkspace]
    }

    private func stamped(_ agents: [AgentSummary]) -> [AgentSummary] {
        agents.map { agent in
            var agent = agent
            agent.hostId = hostId
            return agent
        }
    }

    private func apply(_ snapshot: AgentsSnapshotMessage) {
        available = snapshot.available
        reason = snapshot.reason
        hasLoaded = true
        isStale = false
        isOffline = false
        isRevoked = false
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
        agents = stamped(smoothed)
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
            var measured = false
            while !Task.isCancelled {
                let frame = try await socket.receive()
                guard case let .string(text) = frame else { continue }
                let snapshot = try JSONDecoder().decode(AgentsSnapshotMessage.self, from: Data(text.utf8))
                guard snapshot.type == "agents" else { continue }
                apply(snapshot)
                if !measured {
                    // The first snapshot proves the stream; the round trip
                    // the header shows is measured right behind it.
                    measured = true
                    Task { [weak self] in
                        guard let self, case let .reachable(latency) = await self.probeHost() else { return }
                        self.latencyMilliseconds = latency
                    }
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.info("events stream ended: \(error.localizedDescription)")
            // Keep the last known agents on screen, explicitly stale —
            // dropping them here made "Needs you" blink away on every
            // network blip while the agent was still waiting.
            isStale = true
            // Unless the host is telling us this credential is dead: a
            // WebSocket drop and an HTTP 401 look alike here, so ask the
            // host directly before deciding. The same probe says whether
            // the computer answers at all (#50): "reconnecting" and
            // "offline" are different headers on the home.
            switch await probeHost() {
            case .rejected:
                isRevoked = true
                isOffline = false
                available = false
                reason = "This iPhone is no longer paired with this computer. Pair it again to reconnect."
                hasLoaded = true
                isStale = false
                agents = []
                stop()
            case let .reachable(latency):
                isOffline = false
                latencyMilliseconds = latency
            case .unreachable:
                guard !Task.isCancelled else { return }
                isOffline = true
            }
        }
    }

    enum HostProbe: Equatable {
        // A definite 401: the credential is dead.
        case rejected
        // The host answered (any other status), in this many milliseconds.
        case reachable(latencyMilliseconds: Int)
        // No answer at the connection level: asleep, gone, or we are offline.
        case unreachable
    }

    // Bounded tightly: this runs on every stream drop, including the
    // ordinary background→foreground cycle, and with the default 60 s
    // timeout a half-dead connection after resume held the whole reconnect
    // for a minute (owner-reported). Anything but a definite 401 keeps the
    // stream retrying; only a connection-level failure marks the host
    // offline.
    private func probeHost() async -> HostProbe {
        guard let host, !credential.isEmpty,
              var components = URLComponents(url: host.baseURL, resolvingAgainstBaseURL: false) else { return .unreachable }
        components.path = "/api/host"
        guard let url = components.url else { return .unreachable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        let started = Date()
        guard let (_, response) = try? await Self.session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .unreachable }
        if status == 401 { return .rejected }
        return .reachable(latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }
}
