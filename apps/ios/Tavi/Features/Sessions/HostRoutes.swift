import Foundation
import Observation

// Every route the directory itself calls on one paired computer, and the
// feature clients it hands out. The credential lives here and nowhere
// else in the directory; callers get answers, never the token.
@MainActor
@Observable
final class HostRoutes {
    private var host: HostEndpoint?
    private var credential = ""
    private var hostId = ""

    private static var session: URLSession { HostSession.shared }

    var isConfigured: Bool {
        host != nil && !credential.isEmpty
    }

    func configure(host: HostEndpoint?, credential: String, hostId: String) {
        self.host = host
        self.credential = credential
        self.hostId = hostId
    }

    // The read-only file routes for this computer (#25, #57, #61). The
    // credential stays here; the client only borrows it for GETs. nil until
    // the host is configured.
    var filesClient: HostFilesClient? {
        guard let host, !credential.isEmpty else { return nil }
        return HostFilesClient(endpoint: host, credential: credential)
    }

    // Source Control routes for this computer (#77); same ownership rule.
    var sourceControlClient: HostSourceControlClient? {
        guard let host, !credential.isEmpty else { return nil }
        return HostSourceControlClient(endpoint: host, credential: credential)
    }

    // Dev-server preview routes for this computer (#58); same ownership
    // rule. The web view never sees this credential, only a host ticket.
    var previewClient: HostPreviewClient? {
        guard let host, !credential.isEmpty else { return nil }
        return HostPreviewClient(endpoint: host, credential: credential)
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

    // Worktree and branch visibility (#59a): every repository this host can
    // see, with every worktree git knows about. Polled on its own cadence
    // (dirty state has no push feed) rather than carried on the agents
    // snapshot, so a quiet folder never blocks on it.
    // `fresh` bypasses the host's cache — after the phone itself changed
    // something; the poll takes the cached answer, which is instant.
    func fetchRepos(fresh: Bool = false) async -> ReposFetch {
        guard let host, !credential.isEmpty else { return .failure("Connect a host first.") }
        guard var components = URLComponents(url: host.baseURL, resolvingAgainstBaseURL: false) else {
            return .failure("The host address is invalid.")
        }
        components.path = "/api/repos"
        if fresh { components.queryItems = [URLQueryItem(name: "fresh", value: "1")] }
        guard let url = components.url else { return .failure("The host address is invalid.") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
                return .failure("The host did not answer.")
            }
            return .repos(try JSONDecoder().decode(RepoCatalog.self, from: data).repos)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // Creates a git worktree for a new branch (#75) — the host makes the
    // folder, the caller then starts an agent in it with `createTab`.
    // `allowOutsideRoots` as for `createTab`: only after the person confirmed.
    func createWorktree(repo: String, branch: String, base: String?, allowOutsideRoots: Bool = false) async -> CreateWorktreeOutcome {
        guard let host, !credential.isEmpty else { return .failure("Connect a host first.") }
        guard var components = URLComponents(url: host.baseURL, resolvingAgainstBaseURL: false) else {
            return .failure("The host address is invalid.")
        }
        components.path = "/api/worktrees"
        guard let url = components.url else { return .failure("The host address is invalid.") }

        var body: [String: Any] = ["repo": repo, "branch": branch]
        if let base { body["base"] = base }
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
            if status == 201 {
                guard let created = try? JSONDecoder().decode(CreatedWorktreeResponse.self, from: data) else {
                    return .failure("The host created the worktree but did not say where.")
                }
                return .created(created.worktree)
            }
            let failure = try? JSONDecoder().decode(CreateTabFailure.self, from: data)
            if failure?.outsideRoots == true { return .needsOutsideRootsConfirmation(failure?.error ?? "The new worktree would be outside your project folders.") }
            return .failure(failure?.error ?? "The host could not create the worktree (HTTP \(status)).")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private struct CreatedWorktreeResponse: Decodable {
        let worktree: CreatedWorktree
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
            if status == 201 {
                guard let created = try? JSONDecoder().decode(CreatedTab.self, from: data) else {
                    return .failure("The host created the agent but did not say which pane it lives in.")
                }
                return .created(paneId: created.paneId, tabId: created.tabId)
            }
            let failure = try? JSONDecoder().decode(CreateTabFailure.self, from: data)
            if failure?.outsideRoots == true { return .needsOutsideRootsConfirmation }
            return .failure(failure?.error ?? "The host could not create the tab (HTTP \(status)).")
        } catch {
            return .failure(error.localizedDescription)
        }
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
    func unpairSelf() async -> String? {
        guard let host, !credential.isEmpty else { return "This iPhone is not paired." }
        guard var components = URLComponents(url: host.baseURL, resolvingAgainstBaseURL: false) else {
            return "The host address is invalid."
        }
        components.path = "/api/devices/me"
        guard let url = components.url else { return "The host address is invalid." }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        // A computer that is off waits out the system's 60 s here before
        // the sheet offers "Forget on this iPhone only" (owner, 2026-09-02:
        // "I can't remove a device that is offline"). Ten seconds is
        // plenty for a computer that is on.
        request.timeoutInterval = 10
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
            return .tree(payload.workspaces.map { workspace in
                HerdrTreeWorkspace(
                    workspaceId: workspace.workspaceId,
                    label: workspace.label,
                    focused: workspace.focused,
                    tabs: workspace.tabs.map { tab in
                        HerdrTreeTab(tabId: tab.tabId, label: tab.label, focused: tab.focused, agents: tab.agents.map { $0.stamped(hostId: hostId) })
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

    // The safe, sanitized excerpt behind a home card (#26).
    func preview(paneId: String) async -> String? {
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
