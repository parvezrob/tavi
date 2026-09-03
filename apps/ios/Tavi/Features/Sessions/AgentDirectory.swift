// Over the 400-line line; split in #69.
// swiftlint:disable file_length

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

// How the phone's packets reach the computer, per the computer's own
// Tailscale (#86 / #84): said in words, never coloured as a problem — a
// relay is slower and still private.
enum ConnectionPath: Equatable, Sendable {
    case direct
    case relay(String?)
    case unknown

    init(path: String?, relay: String?) {
        switch path {
        case "direct": self = .direct
        case "relay": self = .relay(relay.flatMap { $0.isEmpty ? nil : $0 })
        default: self = .unknown
        }
    }

    // The word that joins "Live · 7 ms" on the header; nothing for direct,
    // which is the ordinary case and needs no comment.
    var headerSuffix: String? {
        if case .relay = self { return "relay" }
        return nil
    }

    // The sentence on the computer sheet's "Right now" footer.
    var sentence: String? {
        switch self {
        case .direct: "Direct to this computer — the fastest path there is."
        case let .relay(region): "Through a Tailscale relay\(region.map { " (\($0))" } ?? "") — slower, still private. Usual on mobile networks; at home it means the two devices cannot see each other directly on the WiFi."
        case .unknown: nil
        }
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

// One git worktree, from GET /api/repos (#59a): "where is my work
// happening" for the folder a HomeProject already groups by. `path` is the
// worktree's own folder — the same string a project's `cwd` would be when
// an agent runs there.
struct WorktreeInfo: Identifiable, Equatable, Decodable {
    let path: String
    let branch: String?
    let head: String
    let isMain: Bool
    let dirty: Int
    let ahead: Int
    let behind: Int
    let locked: Bool
    let prunable: Bool
    // The branch's open pull request per the host user's `gh` login (#74);
    // nil when none, or when the host cannot ask.
    let pullRequest: PullRequestRef?
    // Inside the computer's project roots (#83): git lists a worktree
    // wherever it lives, but the host's source-control routes answer only
    // inside the roots. An older host does not say; assumed inside.
    var withinRoots: Bool = true

    var id: String { path }

    // The worktree's own name on its row: the branch, or where a detached
    // HEAD stands ("detached · a1b2c3d").
    var title: String {
        if let branch { return branch }
        return head.isEmpty ? "detached" : "detached · \(head.prefix(7))"
    }

    // "PR #48 · ↑3 ↓1 · 2 uncommitted" — the line beneath the branch (#74;
    // approved design, PRD §7.12). "Uncommitted" over git's own "dirty":
    // more familiar to someone who doesn't speak git jargon (owner call,
    // 2026-09-02). Silent about anything that is zero: a clean worktree on
    // the default branch has no second line at all, as the locked design
    // draws it. A worktree whose folder is gone says so instead of posing
    // as live work.
    var summary: String {
        if prunable { return "Folder missing" }
        var parts: [String] = []
        if let pullRequest { parts.append("PR #\(pullRequest.number)") }
        var sync: [String] = []
        if ahead > 0 { sync.append("↑\(ahead)") }
        if behind > 0 { sync.append("↓\(behind)") }
        if !sync.isEmpty { parts.append(sync.joined(separator: " ")) }
        if dirty > 0 { parts.append(dirty == 1 ? "1 uncommitted" : "\(dirty) uncommitted") }
        if locked { parts.append("locked") }
        return parts.joined(separator: " · ")
    }
}

// In an extension so the memberwise initialiser the tests use survives.
extension WorktreeInfo {
    private enum CodingKeys: String, CodingKey { case path, branch, head, isMain, dirty, ahead, behind, locked, prunable, pullRequest, withinRoots }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        head = try container.decode(String.self, forKey: .head)
        isMain = try container.decode(Bool.self, forKey: .isMain)
        dirty = try container.decode(Int.self, forKey: .dirty)
        ahead = try container.decode(Int.self, forKey: .ahead)
        behind = try container.decode(Int.self, forKey: .behind)
        locked = try container.decode(Bool.self, forKey: .locked)
        prunable = try container.decode(Bool.self, forKey: .prunable)
        pullRequest = try container.decodeIfPresent(PullRequestRef.self, forKey: .pullRequest)
        withinRoots = try container.decodeIfPresent(Bool.self, forKey: .withinRoots) ?? true
    }
}

struct PullRequestRef: Equatable, Decodable {
    let number: Int
    let url: String
}

struct RepoInfo: Identifiable, Equatable, Decodable {
    let root: String
    let name: String
    let defaultBranch: String?
    // Local branches, default first — the "start from" choices when
    // creating a worktree (#75). Absent from an older host: empty.
    var branches: [String] = []
    let worktrees: [WorktreeInfo]

    var id: String { root }

    private enum CodingKeys: String, CodingKey { case root, name, defaultBranch, branches, worktrees }

    init(root: String, name: String, defaultBranch: String?, branches: [String] = [], worktrees: [WorktreeInfo]) {
        self.root = root
        self.name = name
        self.defaultBranch = defaultBranch
        self.branches = branches
        self.worktrees = worktrees
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decode(String.self, forKey: .root)
        name = try container.decode(String.self, forKey: .name)
        defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch)
        branches = try container.decodeIfPresent([String].self, forKey: .branches) ?? []
        worktrees = try container.decode([WorktreeInfo].self, forKey: .worktrees)
    }
}

// What the host made when asked for a new worktree (#75).
struct CreatedWorktree: Equatable, Decodable {
    let path: String
    let branch: String
    let base: String
    let repoRoot: String
    let copiedSetupFiles: Int
}

enum CreateWorktreeOutcome: Equatable {
    case created(CreatedWorktree)
    case needsOutsideRootsConfirmation(String)
    case failure(String)
}

private struct RepoCatalog: Decodable {
    let repos: [RepoInfo]
    // Why the host could list nothing (git missing); absent when it ran.
    let error: String?
}

enum ReposFetch: Equatable {
    case repos([RepoInfo])
    case failure(String)
}

// Creating an agent always names a folder. The host owns the rule about
// which folders are ordinary and which need a second look, so a location
// outside its configured roots comes back as a confirmation request rather
// than a failure — the phone asks, then retries with the confirmation.
enum CreateAgentOutcome: Equatable {
    // The host answers with the new pane and tab (#67): the phone opens the
    // terminal on that pane at once instead of leaving you on the home.
    case created(paneId: String, tabId: String)
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
    // Retry cadence for the events stream. A computer that is asleep or off
    // the tailnet is dialled again at 2, 4, 8, 16, then every 30 s — not
    // every 2 s for hours (owner-felt, 2026-09-02: robin-PC unplugged). The
    // connect deadline bounds "Connecting…": a peer that has said nothing
    // after 5 s is probed, and no answer means Offline — the phone never
    // waits out a silent handshake to admit it.
    private static let reconnectPolicy = ReconnectPolicy(
        initialDelay: .seconds(2),
        // Ten, not thirty: a person is looking at this screen, and a link
        // that comes back should be caught within seconds (#86).
        maximumDelay: .seconds(10),
        multiplier: 2,
        connectDeadline: .seconds(5)
    )
    private var reconnectAttempt = 0

    // Every request here carries the bearer token, so it uses the same
    // no-disk-trace policy as the terminal transport (#36): ephemeral
    // storage, no cache, and no silent parking on a dead network path.
    private static var session: URLSession { HostSession.shared }

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
    // Every repository GET /api/repos reported, with its worktrees (#59a,
    // #74). Empty until the first poll answers; a folder no repo claims
    // renders as an ordinary card.
    private(set) var repos: [RepoInfo] = []

    private var credential = ""
    private var host: HostEndpoint?
    private var streamTask: Task<Void, Never>?
    // The live events socket. `stop()` must close it itself: cancelling the
    // task alone leaves `receive()` waiting for the host's next frame, and a
    // quiet host never sends one — the directory, its socket and its buffers
    // then live on (measured 2026-09-02: 242 directories after 200
    // home → terminal → home trips, ~140 KB and one host stream each).
    // Network.framework, not URLSession: see NetworkWebSocketTask (#70).
    private var socket: NetworkWebSocketTask?
    private var previewTask: Task<Void, Never>?
    private let smoother = AgentStatusSmoother()
    // Raw agents from the latest snapshot, re-presented when a pending
    // status de-escalation matures without a new snapshot arriving.
    private var lastRawAgents: [AgentSummary] = []
    private var reviewTask: Task<Void, Never>?
    private var latencyTask: Task<Void, Never>?
    private static let latencyInterval: Duration = .seconds(30)
    private var reposTask: Task<Void, Never>?
    private var reposFailures = 0
    static let reposFailuresBeforeClearing = 3
    // Reconnect coordination (#86, PRD §7.13): one probe in flight however
    // many askers; Offline only after two dials in a row produced no frame;
    // the backoff resets only once the stream has been up for a while.
    private var probeInFlight: Task<HostProbe, Never>?
    private var consecutiveFailedDials = 0
    private var streamConnectedAt: Date?
    private static let stableStreamInterval: TimeInterval = 30
    // How this phone reaches the computer, per the computer's own Tailscale
    // (`GET /api/host` → `connection`); `.unknown` from an older host.
    private(set) var connection: ConnectionPath = .unknown
    // Dirty state changes at typing speed but nobody needs it that fresh;
    // this matches the latency probe's cadence rather than inventing a new
    // rhythm to reason about.
    private static let reposInterval: Duration = .seconds(30)

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
        // `repos` is kept across a restart on purpose: the agents snapshot
        // lands before the first repos poll, and an empty list in between
        // regrouped every worktree as a plain folder for a frame (owner,
        // 2026-09-02: "a blip"). It is this computer's own last answer and
        // the poll replaces it within a second.
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
        // A foreground is a fresh start (#86, owner 2026-09-03 01:10: "the
        // reconnection took a while" after the phone had been idle): the
        // dials that count are the ones from now, so the backoff and the
        // failed-dial count begin at zero, and the first redial after a
        // wake-up failure is 2 s away, not 30.
        reconnectAttempt = 0
        consecutiveFailedDials = 0
        // Offline stays Offline until a snapshot proves otherwise. Resetting
        // it here showed "Connecting…" on every foreground for as long as
        // the handshake took to time out — for an unplugged computer, every
        // time the owner looked (2026-09-02).
        let credential = credential
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.streamOnce(eventsURL: eventsURL, credential: credential)
                guard !Task.isCancelled else { return }
                self.reconnectAttempt += 1
                try? await Task.sleep(for: Self.reconnectPolicy.delay(forAttempt: self.reconnectAttempt))
            }
        }
        latencyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.latencyInterval)
                guard !Task.isCancelled, let self else { return }
                guard self.hasLoaded, !self.isStale else { continue }
                if case let .reachable(latency) = await self.probeHostShared() {
                    self.latencyMilliseconds = latency
                }
            }
        }
        reposTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Not gated on `hasLoaded`/`isStale` the way the latency
                // probe is: those flip only once the events *stream* has
                // delivered a snapshot, which a fresh launch has not done
                // yet, and gating on them here left the first poll waiting
                // out a full interval before trying at all. This is a
                // separate authenticated GET that fails cheaply on its own
                // (`fetchRepos` guards on host/credential) when there is
                // nothing to answer it — `isRevoked` is the one state worth
                // skipping, a dead credential that redialing cannot fix.
                // `isStale` too: while the stream is down this poll would
                // only add a 20 s half-open socket to the redial's own.
                if !self.isRevoked, !self.isOffline, !self.isStale {
                    switch await self.fetchRepos() {
                    case let .repos(repos):
                        self.reposFailures = 0
                        // Equatable, so an unchanged answer never triggers the
                        // @Observable re-render every poll would otherwise cost
                        // the whole home for state that rarely moves.
                        if repos != self.repos { self.repos = repos }
                    case .failure:
                        // A live host that cannot answer this route (git
                        // gone, a broken answer) must not leave last week's
                        // branches on the cards for good (#72): after a few
                        // misses the cards fall back to plain folders.
                        self.reposFailures += 1
                        if self.reposFailures >= Self.reposFailuresBeforeClearing, !self.repos.isEmpty { self.repos = [] }
                    }
                }
                // Jittered so it never ticks in lockstep with the latency
                // probe's 30 s (cold review, 2026-09-02).
                try? await Task.sleep(for: Self.reposInterval * Double.random(in: 0.8...1.2))
            }
        }
    }

    // One immediate repos poll, after the phone changed something (#81
    // removed a worktree) and should not wait out the interval to see it.
    func refreshRepos() async {
        if case let .repos(repos) = await fetchRepos(fresh: true), repos != self.repos { self.repos = repos }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        previewTask?.cancel()
        previewTask = nil
        reviewTask?.cancel()
        reviewTask = nil
        latencyTask?.cancel()
        latencyTask = nil
        reposTask?.cancel()
        reposTask = nil
        isRunning = false
        // Whatever we show next launch/foreground is last-known until the
        // stream confirms otherwise.
        if hasLoaded { isStale = true }
    }

    var isConfigured: Bool {
        host != nil && !credential.isEmpty
    }

    // The read-only file routes for this computer (#25, #57, #61). The
    // directory stays the owner of the credential; the client only borrows
    // it for GETs. nil until the host is configured.
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
        // A handshake that gets no answer must fail on its own clock, not
        // the system's minute-long default: the deadline below decides what
        // the home says, this decides when the attempt is abandoned.
        // Eight seconds: a handshake through a relay takes about one; a
        // radio that is still waking up must fail fast so the redial runs.
        request.timeoutInterval = 8
        let socket = NetworkWebSocketTask(request: request)
        self.socket = socket
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            if self.socket === socket { self.socket = nil }
        }

        // Bounded "Connecting…": if nothing has arrived by the deadline,
        // ask the host directly; no answer at all is Offline, said now,
        // while the attempt keeps going in case it is merely slow. The
        // first frame cancels this, and a probe that lands after a frame
        // is discarded — the frame is the truth.
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.reconnectPolicy.connectDeadline)
            guard !Task.isCancelled, let self else { return }
            let probe = await self.probeHostTwice()
            guard !Task.isCancelled else { return }
            // Earned, not guessed (#86): the first dial that fails is
            // "Connecting…" or "Reconnecting"; Offline waits for the next.
            if probe == .unreachable, self.consecutiveFailedDials >= 1 { self.isOffline = true }
        }
        defer { deadline.cancel() }

        // Snapshots arrive on change only, so a dead socket looks exactly
        // like a quiet evening: ping after 30 s of silence, cycle at 45 s
        // (#86). The host's WebSocket server answers pings on its own.
        let watchdog = Task { [weak socket] in
            var pinged = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let socket else { return }
                let idle = Date().timeIntervalSince(socket.lastActivity)
                if idle >= 45 {
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
                if idle >= 30, !pinged {
                    pinged = true
                    try? await socket.ping()
                } else if idle < 30 {
                    pinged = false
                }
            }
        }
        defer { watchdog.cancel() }

        var measured = false
        defer {
            // A dial that never produced a frame counts against the
            // computer; one that did resets the count.
            if measured { consecutiveFailedDials = 0 } else { consecutiveFailedDials += 1 }
            streamConnectedAt = nil
        }
        do {
            while !Task.isCancelled {
                let frame = try await socket.receive()
                deadline.cancel()
                guard case let .string(text) = frame else { continue }
                let snapshot = try JSONDecoder().decode(AgentsSnapshotMessage.self, from: Data(text.utf8))
                guard snapshot.type == "agents" else { continue }
                apply(snapshot)
                if streamConnectedAt == nil { streamConnectedAt = Date() }
                // The backoff forgets only once the stream has held for a
                // while; a link that works for one frame and dies stays on
                // the slow end of the schedule (#86).
                if let since = streamConnectedAt, Date().timeIntervalSince(since) >= Self.stableStreamInterval { reconnectAttempt = 0 }
                if !measured {
                    // The first snapshot proves the stream; the round trip
                    // the header shows is measured right behind it.
                    measured = true
                    Task { [weak self] in
                        guard let self, case let .reachable(latency) = await self.probeHostShared() else { return }
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
            // The probe runs beside the redial, never in front of it: the
            // reconnect backoff starts the moment the stream drops. Waiting
            // out the double probe here (up to 11.5 s) before redialing made
            // the app miss every short good window on a WiFi link that goes
            // deaf for seconds at a time — the old single 3 s probe never
            // did (three cold reviews, 2026-09-02 night). A snapshot that
            // lands before the probe answers wins: the probe then says
            // nothing about "offline".
            Task { [weak self] in
                guard let self else { return }
                switch await self.probeHostTwice() {
                case .rejected:
                    self.isRevoked = true
                    self.isOffline = false
                    self.available = false
                    self.reason = "This iPhone is no longer paired with this computer. Pair it again to reconnect."
                    self.hasLoaded = true
                    self.isStale = false
                    self.agents = []
                    self.stop()
                case let .reachable(latency):
                    self.isOffline = false
                    self.latencyMilliseconds = latency
                case .unreachable:
                    if self.isStale, self.consecutiveFailedDials >= 2 { self.isOffline = true }
                }
            }
        }
    }

    // Offline is said only after two misses a moment apart: one slow
    // round trip on a jittery WiFi hop must not flip a live computer to
    // "isn't answering" (owner-felt, 2026-09-02 evening).
    private func probeHostTwice() async -> HostProbe {
        let first = await probeHostShared()
        guard first == .unreachable, !Task.isCancelled else { return first }
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled else { return first }
        return await probeHostShared()
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
        request.timeoutInterval = 5
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        let started = Date()
        guard let (data, response) = try? await Self.session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .unreachable }
        if status == 401 { return .rejected }
        if status == 200, let answer = try? JSONDecoder().decode(HostAnswer.self, from: data) {
            let path = ConnectionPath(path: answer.connection?.path, relay: answer.connection?.relay)
            if path != connection { connection = path }
        }
        return .reachable(latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }

    // Single-flight: the connect deadline, the drop path and the latency
    // poll all ask the same question; on a bad link they used to ask it
    // four times at once (#86).
    private func probeHostShared() async -> HostProbe {
        if let probeInFlight { return await probeInFlight.value }
        let task = Task { [weak self] in
            await self?.probeHost() ?? .unreachable
        }
        probeInFlight = task
        defer { if probeInFlight == task { probeInFlight = nil } }
        return await task.value
    }

    private struct HostAnswer: Decodable {
        struct Connection: Decodable {
            let path: String
            let relay: String?
        }

        let connection: Connection?
    }
}
