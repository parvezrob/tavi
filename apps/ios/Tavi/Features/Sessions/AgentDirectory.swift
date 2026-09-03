import Foundation
import Observation

// Live mirror of the host's /api/events feed: a full agents snapshot on
// connect and on every change. State is exactly what the host pushed —
// never inferred client-side. The link that carries it belongs to
// HostConnection, the excerpts to AgentPreviews, the routes to HostRoutes;
// this owns what the home reads about the agents themselves.
@MainActor
@Observable
final class AgentDirectory {
    private(set) var agents: [AgentSummary] = []
    private(set) var available = false
    private(set) var reason: String?
    // Which paired computer this directory mirrors (#50).
    private(set) var hostId = ""
    // When this phone last saw the agent's status change. Honest client-side
    // freshness: after a reconnect the clock restarts at the replayed
    // snapshot, so it never claims more history than the phone witnessed.
    private(set) var statusObservedAt: [String: Date] = [:]
    // Every repository GET /api/repos reported, with its worktrees (#59a,
    // #74). Empty until the first poll answers; a folder no repo claims
    // renders as an ordinary card.
    private(set) var repos: [RepoInfo] = []

    private let link: HostConnection
    private let previewer = AgentPreviews()
    private let routes: HostRoutes
    private let smoother = AgentStatusSmoother()
    // Raw agents from the latest snapshot, re-presented when a pending
    // status de-escalation matures without a new snapshot arriving.
    private var lastRawAgents: [AgentSummary] = []
    private var reviewTask: Task<Void, Never>?
    private var reposTask: Task<Void, Never>?
    private var reposFailures = 0
    static let reposFailuresBeforeClearing = 3
    // Dirty state changes at typing speed but nobody needs it that fresh;
    // this matches the latency probe's cadence rather than inventing a new
    // rhythm to reason about.
    private static let reposInterval: Duration = .seconds(30)

    // Tests hand in their own transport and socket, the seam the link and
    // the routes already have, so no unit test opens a real one (#99).
    init(
        transport: @escaping HostClient.Transport = { try await HostSession.shared.data(for: $0) },
        makeSocket: @escaping @Sendable (URLRequest) -> any HostEventsSocketing = { NetworkWebSocketTask(request: $0) }
    ) {
        link = HostConnection(transport: transport, makeSocket: makeSocket)
        routes = HostRoutes(transport: transport)
    }

    // What the home reads about the link, from the type that owns it.
    var health: HostHealth { link.health }
    var hasLoaded: Bool { link.hasLoaded }
    var latencyMilliseconds: Int? { link.latencyMilliseconds }
    var connection: ConnectionPath { link.path }
    var previews: [String: String] { previewer.previews }
    var isConfigured: Bool { routes.isConfigured }

    var filesClient: HostFilesClient? { routes.filesClient }
    var sourceControlClient: HostSourceControlClient? { routes.sourceControlClient }
    var previewClient: HostPreviewClient? { routes.previewClient }

    func configure(hostId: String, hostText: String, credential: String) {
        stop()
        self.hostId = hostId
        // A different host is a different world: never show one host's
        // agents as another's "last known state".
        agents = []
        statusObservedAt = [:]
        available = false
        reason = nil
        // `repos` is kept across a restart on purpose: the agents snapshot
        // lands before the first repos poll, and an empty list in between
        // regrouped every worktree as a plain folder for a frame (owner,
        // 2026-09-02: "a blip"). It is this computer's own last answer and
        // the poll replaces it within a second.
        lastRawAgents = []
        smoother.reset()
        let endpoint = URL(string: hostText).flatMap { try? HostEndpoint(baseURL: $0) }
        let usable = endpoint != nil && !credential.isEmpty
        routes.configure(host: usable ? endpoint : nil, credential: usable ? credential : "", hostId: hostId)
        previewer.configure(routes: routes)
        if !usable {
            // Nothing can connect without a credential or a valid address.
            // The link says so as a revocation; these are the words for it.
            reason = credential.isEmpty
                ? "Tavi no longer has a credential for this computer. Pair it again to reconnect."
                : "This computer's address is not valid any more. Pair it again to reconnect."
        }
        link.configure(host: usable ? endpoint : nil, credential: usable ? credential : "") { [weak self] event in
            self?.handle(event)
        }
        startReposPoll()
    }

    func start() {
        link.start()
        startReposPoll()
    }

    func stop() {
        link.stop()
        previewer.cancel()
        reviewTask?.cancel()
        reviewTask = nil
        reposTask?.cancel()
        reposTask = nil
    }

    // One immediate repos poll, after the phone changed something (#81
    // removed a worktree) and should not wait out the interval to see it.
    func refreshRepos() async {
        if case let .repos(repos) = await routes.fetchRepos(fresh: true), repos != self.repos { self.repos = repos }
    }

    // The directory is the only door to this computer: it owns the
    // credential's owner and hands out answers, never the token.
    func fetchProjects() async -> ProjectsFetch {
        await routes.fetchProjects()
    }

    func fetchRepos(fresh: Bool = false) async -> ReposFetch {
        await routes.fetchRepos(fresh: fresh)
    }

    func createWorktree(repo: String, branch: String, base: String?, allowOutsideRoots: Bool = false) async -> CreateWorktreeOutcome {
        await routes.createWorktree(repo: repo, branch: branch, base: base, allowOutsideRoots: allowOutsideRoots)
    }

    func createTab(agent: String?, cwd: String, allowOutsideRoots: Bool = false) async -> CreateAgentOutcome {
        await routes.createTab(agent: agent, cwd: cwd, allowOutsideRoots: allowOutsideRoots)
    }

    func unpairSelf() async -> String? {
        await routes.unpairSelf()
    }

    func fetchDialog(paneId: String) async -> DialogFetch {
        await routes.fetchDialog(paneId: paneId)
    }

    func decide(paneId: String, decision: DialogDecision) async -> DecisionOutcome {
        await routes.decide(paneId: paneId, decision: decision)
    }

    func renameTab(tabId: String, label: String) async -> String? {
        await routes.renameTab(tabId: tabId, label: label)
    }

    func promptAgent(paneId: String, text: String) async -> String? {
        await routes.promptAgent(paneId: paneId, text: text)
    }

    func fetchTree() async -> HerdrTreeFetch {
        await routes.fetchTree()
    }

    private func handle(_ event: HostConnectionEvent) {
        switch event {
        case let .snapshot(agents, available, reason):
            self.available = available
            self.reason = reason
            lastRawAgents = agents
            present(agents)
        case let .revoked(reason):
            available = false
            self.reason = reason
            agents = []
            stop()
        }
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
        agents = smoothed.map { $0.stamped(hostId: hostId) }
        previewer.prune(keeping: Set(observed.keys))
        previewer.refresh(for: agents)

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

    private func startReposPoll() {
        guard reposTask == nil, routes.isConfigured, !link.isRevoked else { return }
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
                if self.link.isPollable {
                    switch await self.routes.fetchRepos() {
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
}
