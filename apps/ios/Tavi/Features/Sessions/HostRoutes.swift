import Foundation
import Observation

// Every route the directory itself calls on one paired computer, and the
// feature clients it hands out. The credential lives here and nowhere
// else in the directory; callers get answers, never the token. Every
// request is built, sent and read by HostClient (#96), so the bearer, the
// query, the JSON body and the #81 too-old sentence have one home.
@MainActor
@Observable
final class HostRoutes {
    private var host: HostEndpoint?
    private var credential = ""
    private var hostId = ""
    private let transport: HostClient.Transport

    // Tests hand in their own transport so no unit test opens a socket (#99).
    init(transport: @escaping HostClient.Transport = { try await HostSession.shared.data(for: $0) }) {
        self.transport = transport
    }

    // A route the host does not have answers a bare `Not found.`; on the
    // directory's routes that is an old host, and this says what to do.
    private static let tooOld = "This computer's Tavi host is too old to do that. Update it with `npx tavi-host update`."

    private static func sentences(answer: String, cannotAnswer: String) -> HostClient.Sentences {
        HostClient.Sentences(answer: answer, tooOld: tooOld, cannotAnswer: cannotAnswer)
    }

    // Both refusal shapes read the same to a caller here: a sentence to show.
    private static func fetched<Value, Fetch>(
        _ reply: HostClient.Reply<Value>,
        _ value: (Value) -> Fetch,
        _ failure: (String) -> Fetch
    ) -> Fetch {
        switch reply {
        case let .value(answer): return value(answer)
        case let .refused(_, sentence, _): return failure(sentence)
        case let .failure(reason): return failure(reason)
        }
    }

    // A route whose answer is a message: nil when the host did what was
    // asked, its own words when it did not.
    private static func message(
        _ answer: HostClient.Answer,
        saying sentences: HostClient.Sentences,
        accepting isDone: (Int) -> Bool
    ) -> String? {
        switch answer {
        case let .failure(reason):
            return reason
        case let .answered(status, body, _):
            return isDone(status) ? nil : HostClient.refusalMessage(status: status, body: body, saying: sentences)
        }
    }

    var isConfigured: Bool {
        client != nil
    }

    func configure(host: HostEndpoint?, credential: String, hostId: String) {
        self.host = host
        self.credential = credential
        self.hostId = hostId
    }

    private var client: HostClient? {
        guard let host, !credential.isEmpty else { return nil }
        return HostClient(endpoint: host, credential: credential, transport: transport)
    }

    // The read-only file routes for this computer (#25, #57, #61). The
    // credential stays here; the client only borrows it for GETs. nil until
    // the host is configured.
    var filesClient: HostFilesClient? {
        guard let host, !credential.isEmpty else { return nil }
        return HostFilesClient(endpoint: host, credential: credential, transport: transport)
    }

    // Source Control routes for this computer (#77); same ownership rule.
    var sourceControlClient: HostSourceControlClient? {
        guard let host, !credential.isEmpty else { return nil }
        return HostSourceControlClient(endpoint: host, credential: credential, transport: transport)
    }

    // Dev-server preview routes for this computer (#58); same ownership
    // rule. The web view never sees this credential, only a host ticket.
    var previewClient: HostPreviewClient? {
        guard let host, !credential.isEmpty else { return nil }
        return HostPreviewClient(endpoint: host, credential: credential, transport: transport)
    }

    // The folders the New Agent picker offers (#24). One call: recent
    // choices plus the browsable roots, both ordered by the host.
    func fetchProjects() async -> ProjectsFetch {
        guard let client else { return .failure("Connect a host first.") }
        let reply: HostClient.Reply<ProjectCatalog> = await client.fetch(
            "GET",
            "/api/projects",
            saying: Self.sentences(answer: "a project list", cannotAnswer: "The host could not list your projects")
        )
        return Self.fetched(reply, ProjectsFetch.catalog, ProjectsFetch.failure)
    }

    // Worktree and branch visibility (#59a): every repository this host can
    // see, with every worktree git knows about. Polled on its own cadence
    // (dirty state has no push feed) rather than carried on the agents
    // snapshot, so a quiet folder never blocks on it.
    // `fresh` bypasses the host's cache — after the phone itself changed
    // something; the poll takes the cached answer, which is instant.
    func fetchRepos(fresh: Bool = false) async -> ReposFetch {
        guard let client else { return .failure("Connect a host first.") }
        let reply: HostClient.Reply<RepoCatalog> = await client.fetch(
            "GET",
            "/api/repos",
            query: fresh ? ["fresh": "1"] : [:],
            timeout: 20,
            saying: Self.sentences(answer: "a repository list", cannotAnswer: "The host could not list the repositories")
        )
        return Self.fetched(reply, { .repos($0.repos) }, ReposFetch.failure)
    }

    // Creates a git worktree for a new branch (#75) — the host makes the
    // folder, the caller then starts an agent in it with `createTab`.
    // `allowOutsideRoots` as for `createTab`: only after the person confirmed.
    func createWorktree(repo: String, branch: String, base: String?, allowOutsideRoots: Bool = false) async -> CreateWorktreeOutcome {
        guard let client else { return .failure("Connect a host first.") }
        var body: [String: Any] = ["repo": repo, "branch": branch]
        if let base { body["base"] = base }
        if allowOutsideRoots { body["allowOutsideRoots"] = true }
        switch await client.send("POST", "/api/worktrees", body: body) {
        case let .failure(reason):
            return .failure(reason)
        case let .answered(status, data, _):
            guard status == 201 else { return Self.refusedCreation(status: status, data: data) }
            guard let created = try? JSONDecoder().decode(CreatedWorktreeResponse.self, from: data) else {
                return .failure("The host created the worktree but did not say where.")
            }
            return .created(created.worktree)
        }
    }

    // The host owns the roots rule, so a location it flags comes back as a
    // question for the person rather than a failure.
    private static func refusedCreation(status: Int, data: Data) -> CreateWorktreeOutcome {
        let failure = try? JSONDecoder().decode(CreateTabFailure.self, from: data)
        if failure?.outsideRoots == true {
            return .needsOutsideRootsConfirmation(failure?.error ?? "The new worktree would be outside your project folders.")
        }
        return .failure(HostClient.refusalMessage(
            status: status,
            body: data,
            saying: sentences(answer: "a new worktree", cannotAnswer: "The host could not create the worktree")
        ))
    }

    private struct CreatedWorktreeResponse: Decodable {
        let worktree: CreatedWorktree
    }

    // Creates a Herdr tab in a chosen project folder and launches the agent
    // in it. The new agent then arrives through the live snapshot feed like
    // any other. `allowOutsideRoots` is the phone confirming a location the
    // host flagged as outside its project roots — never sent unprompted.
    func createTab(agent: String?, cwd: String, allowOutsideRoots: Bool = false) async -> CreateAgentOutcome {
        guard let client else { return .failure("Connect a host first.") }
        var body: [String: Any] = ["cwd": cwd]
        if let agent { body["agent"] = agent }
        if allowOutsideRoots { body["allowOutsideRoots"] = true }
        switch await client.send("POST", "/api/herdr/tabs", body: body) {
        case let .failure(reason):
            return .failure(reason)
        case let .answered(status, data, _):
            guard status == 201 else { return Self.refusedTab(status: status, data: data) }
            guard let created = try? JSONDecoder().decode(CreatedTab.self, from: data) else {
                return .failure("The host created the agent but did not say which pane it lives in.")
            }
            return .created(paneId: created.paneId, tabId: created.tabId)
        }
    }

    private static func refusedTab(status: Int, data: Data) -> CreateAgentOutcome {
        let failure = try? JSONDecoder().decode(CreateTabFailure.self, from: data)
        if failure?.outsideRoots == true { return .needsOutsideRootsConfirmation }
        return .failure(HostClient.refusalMessage(
            status: status,
            body: data,
            saying: sentences(answer: "a new agent", cannotAnswer: "The host could not create the tab")
        ))
    }

    private struct CreatedTab: Decodable {
        let paneId: String
        let tabId: String
    }

    private struct CreateTabFailure: Decodable {
        let error: String?
        let outsideRoots: Bool?
    }

    // Asks the host to revoke this phone's own credential (#46). nil on
    // success; a message when the host could not be reached or refused —
    // the caller then decides whether to forget locally anyway.
    // Ten seconds, not the system's sixty: a computer that is off must not
    // hold the sheet before it offers "Forget on this iPhone only" (owner,
    // 2026-09-02: "I can't remove a device that is offline").
    func unpairSelf() async -> String? {
        guard let client else { return "This iPhone is not paired." }
        let answer = await client.send("DELETE", "/api/devices/me", timeout: 10)
        if case let .failure(reason) = answer { return "Could not reach the computer: \(reason)" }
        // 401 means the credential is already dead: unpaired either way.
        return Self.message(
            answer,
            saying: Self.sentences(answer: "an unpair answer", cannotAnswer: "The computer could not unpair this iPhone"),
            accepting: { $0 == 204 || $0 == 401 }
        )
    }

    // Reads the live permission dialog on a waiting agent's pane (#23) so the
    // Needs-you sheet can show the real choices. `.none` means no dialog is
    // currently rendered (it may have just resolved).
    func fetchDialog(paneId: String) async -> DialogFetch {
        guard let client else { return .failure("Connect a host first.") }
        let reply: HostClient.Reply<DialogResponse> = await client.fetch(
            "GET",
            "/api/agents/\(paneId)/dialog",
            saying: Self.sentences(answer: "a dialog", cannotAnswer: "The host could not read the dialog")
        )
        return Self.fetched(reply, { payload in
            guard payload.present, let dialog = payload.dialog else { return DialogFetch.none }
            return .dialog(dialog)
        }, DialogFetch.failure)
    }

    // Answers a waiting permission from the phone (#23). The host re-reads the
    // pane and refuses (409) if the dialog is already gone; that surfaces as
    // `.stale` so the sheet can say the wait resolved instead of implying the
    // tap did something. Returns `.ok` on a delivered decision.
    func decide(paneId: String, decision: DialogDecision) async -> DecisionOutcome {
        guard let client else { return .failure("Connect a host first.") }
        let answer = await client.send("POST", "/api/agents/\(paneId)/decision", body: decisionBody(decision))
        if case .answered(409, _, _) = answer { return .stale }
        let message = Self.message(
            answer,
            saying: Self.sentences(answer: "a decision answer", cannotAnswer: "The host could not deliver the decision"),
            accepting: { $0 == 200 }
        )
        return message.map(DecisionOutcome.failure) ?? .ok
    }

    private func decisionBody(_ decision: DialogDecision) -> [String: Any] {
        switch decision {
        case .approve: return ["decision": "approve"]
        case .deny: return ["decision": "deny"]
        case let .option(index): return ["decision": "option", "option": index]
        }
    }

    // Renames the herdr tab behind a pane (#55). Returns a user-facing
    // error message, nil on success; the new label reaches every phone
    // through the events feed like any other change.
    func renameTab(tabId: String, label: String) async -> String? {
        guard let client else { return "Connect a host first." }
        return Self.message(
            await client.send("PATCH", "/api/herdr/tabs/\(tabId)", body: ["label": label]),
            saying: Self.sentences(answer: "a rename answer", cannotAnswer: "The host could not rename the tab"),
            accepting: { $0 == 200 }
        )
    }

    // Deliberate composer send for an agent target via the host's prompt
    // endpoint. Submits exactly once; returns a user-facing error message
    // on failure, nil on success. Note the host-side contract: the text
    // appends to whatever is already typed in the agent's own composer.
    func promptAgent(paneId: String, text: String) async -> String? {
        guard let client else { return "Connect a host first." }
        return Self.message(
            await client.send("POST", "/api/agents/\(paneId)/prompt", body: ["text": text]),
            saying: Self.sentences(answer: "a prompt answer", cannotAnswer: "The host could not deliver the prompt"),
            accepting: { [200, 202, 204].contains($0) }
        )
    }

    func fetchTree() async -> HerdrTreeFetch {
        guard let client else { return .failure("Connect a host first.") }
        let reply: HostClient.Reply<TreeResponse> = await client.fetch(
            "GET",
            "/api/herdr/tree",
            saying: Self.sentences(answer: "a workspace list", cannotAnswer: "The host could not list the workspaces")
        )
        return Self.fetched(reply, { payload in
            .tree(payload.workspaces.map { workspace in
                HerdrTreeWorkspace(
                    workspaceId: workspace.workspaceId,
                    label: workspace.label,
                    focused: workspace.focused,
                    tabs: workspace.tabs.map { tab in
                        HerdrTreeTab(tabId: tab.tabId, label: tab.label, focused: tab.focused, agents: tab.agents.map { $0.stamped(hostId: hostId) })
                    }
                )
            })
        }, HerdrTreeFetch.failure)
    }

    private struct TreeResponse: Decodable {
        let workspaces: [HerdrTreeWorkspace]
    }

    // The safe, sanitized excerpt behind a home card (#26). A card without
    // an excerpt is ordinary, so every failure here is silence.
    func preview(paneId: String) async -> String? {
        guard let client else { return nil }
        let reply: HostClient.Reply<PreviewResponse> = await client.fetch(
            "GET",
            "/api/agents/\(paneId)/preview",
            query: ["lines": "6"],
            saying: Self.sentences(answer: "an excerpt", cannotAnswer: "The host could not read the excerpt")
        )
        guard case let .value(payload) = reply else { return nil }
        return payload.preview
    }

    private struct PreviewResponse: Decodable {
        let preview: String
    }
}

private struct RepoCatalog: Decodable {
    let repos: [RepoInfo]
    // Why the host could list nothing (git missing); absent when it ran.
    let error: String?
}

private struct DialogResponse: Decodable {
    let present: Bool
    let dialog: PermissionDialog?
}
