import Foundation

// The home reads computer → project → worktree → agents (#26, #50, #74). A
// project is a folder: a git repository when the host knows one (its main
// worktree's path is the card; every worktree the repository has is a
// group inside it, wherever on disk it lives), else just the folder an
// agent lives in. A computer is the paired host that reported it. Every
// paired computer gets its own group with its own connection health, in
// pairing order, so a host that is asleep is a quiet "Offline" header and
// never a blank home.
//
// What needs the user is deliberately *not* rendered inside the groups: a
// waiting agent must never sit under a project the eye has skipped, so
// needs-you stays a flat list above everything (PRD §7.1). The project it
// belongs to still knows about it — the header counts it — so a folder does
// not vanish and reappear as its agent blocks and resumes.

// One worktree inside a project's card (#74): the branch and its git
// state, and the agents whose cwd sits under it. A worktree with no agent
// still shows — it is work in progress whether or not something is
// running there right now.
struct HomeWorktree: Identifiable, Equatable {
    let info: WorktreeInfo
    let needsYou: [AgentSummary]
    let active: [AgentSummary]
    let recent: [AgentSummary]

    var id: String { info.path }
    var agentCount: Int { needsYou.count + active.count + recent.count }
}

struct HomeProject: Identifiable, Equatable {
    // A repository's main worktree, or the cwd as the host reported it,
    // trailing slashes trimmed. The phone does not try to be cleverer about
    // paths than the host that produced them.
    let path: String
    let name: String
    // Agents in this folder that no worktree claims — every agent, for a
    // folder the host knows no repository for. Needs-you is rendered flat
    // above the groups and counted here.
    let needsYou: [AgentSummary]
    let active: [AgentSummary]
    let recent: [AgentSummary]
    // In the host's order: the main worktree first, as git lists them.
    let worktrees: [HomeWorktree]

    var id: String { path }
    var abbreviatedPath: String { path.abbreviatingHomeDirectory }
    var isRepository: Bool { !worktrees.isEmpty }
    var agentCount: Int {
        needsYou.count + active.count + recent.count + worktrees.reduce(0) { $0 + $1.agentCount }
    }
    var needsYouCount: Int { needsYou.count + worktrees.reduce(0) { $0 + $1.needsYou.count } }
    // Something to draw under the header. A repository always has its
    // worktree groups — the card must not blink out while its one agent
    // asks a question (review, 2026-09-02). A plain folder shows only for
    // agent rows: needs-you is rendered above the cards, and a plain card
    // with nothing under its header is noise.
    var hasRows: Bool {
        isRepository || !active.isEmpty || !recent.isEmpty
    }
}

// One paired computer as the home renders it: identity, how the phone is
// doing against it right now, and its projects. A computer with no
// projects still renders — its header is where the health lives.
struct HomeComputer: Identifiable, Equatable {
    let id: String
    let name: String
    let health: HostHealth
    let latencyMilliseconds: Int?
    // False until the first snapshot: the group shows "Connecting…"
    // instead of "no agents".
    let hasLoaded: Bool
    // The host reached us but its agent feed is not usable (herdr down);
    // `reason` is the host's own explanation.
    let available: Bool
    let reason: String?
    let projects: [HomeProject]
    var connection: ConnectionPath = .unknown

    var agentCount: Int { projects.reduce(0) { $0 + $1.agentCount } }
    // Reachable, feed usable, still paired — nothing to explain.
    var isQuietlyIdle: Bool { hasLoaded && available && health != .revoked }
    var waitingCount: Int { projects.reduce(0) { $0 + $1.needsYouCount } }

    // "Live · 40 ms · 8 agents · 5 waiting" — the computer in one line,
    // for its chip's spoken value, the Computers menu, and its sheet.
    var summary: String {
        var parts = [health.label(latencyMilliseconds: latencyMilliseconds, connection: connection)]
        // Counts only for what is being reported now; an offline or
        // unpaired computer's numbers are history, not a summary.
        if hasLoaded, health == .live || health == .stale {
            parts.append(agentCount == 1 ? "1 agent" : "\(agentCount) agents")
            if waitingCount > 0 { parts.append("\(waitingCount) waiting") }
        }
        return parts.joined(separator: " · ")
    }
}

// What one host contributes to the layout: its identity and its
// directory's current state, flattened so grouping is a pure function.
struct HomeHostInput: Equatable {
    let id: String
    let name: String
    let agents: [AgentSummary]
    let health: HostHealth
    let latencyMilliseconds: Int?
    let hasLoaded: Bool
    let available: Bool
    let reason: String?
    // Every repository this host's GET /api/repos reported (#59a, #74).
    let repos: [RepoInfo]
    // How the phone reaches this computer, per its own Tailscale (#86).
    let connection: ConnectionPath

    init(
        id: String,
        name: String,
        agents: [AgentSummary],
        health: HostHealth = .live,
        latencyMilliseconds: Int? = nil,
        hasLoaded: Bool = true,
        available: Bool = true,
        reason: String? = nil,
        repos: [RepoInfo] = [],
        connection: ConnectionPath = .unknown
    ) {
        self.id = id
        self.name = name
        self.agents = agents
        self.health = health
        self.latencyMilliseconds = latencyMilliseconds
        self.hasLoaded = hasLoaded
        self.available = available
        self.reason = reason
        self.repos = repos
        self.connection = connection
    }
}

// Waiting agents the phone cannot tell apart — same computer, same kind,
// same identity line, same asking line (usually none: herdr-restored
// `claude --resume` panes with blank screens) — render as one stacked row
// that expands in place (owner call 2026-09-02). A real question never
// merges: the asking line is part of the key.
struct WaitingGroup: Identifiable, Equatable {
    let key: String
    let agents: [AgentSummary]
    let askingLine: String?

    var id: String { key }
    var isStacked: Bool { agents.count > 1 }
    var primary: AgentSummary { agents[0] }
}

struct HomeLayout: Equatable {
    let needsYou: [AgentSummary]
    let computers: [HomeComputer]

    // No agent anywhere — the computers still render their headers.
    var isEmpty: Bool {
        needsYou.isEmpty && computers.allSatisfy { $0.projects.isEmpty }
    }
}

enum HomeGrouping {
    // Needs-you is flat and first across every computer, in host order
    // then the host's own order: a waiting agent on the Linux box must not
    // hide under a collapsed Mac group. Computers keep their pairing order
    // so a group never moves as its health or agents change.
    static func layout(hosts: [HomeHostInput]) -> HomeLayout {
        let needsYou = hosts.flatMap { host in host.agents.filter { $0.homeSection == .needsYou } }
        let computers = hosts.map { host in
            HomeComputer(
                id: host.id,
                name: host.name,
                health: host.health,
                latencyMilliseconds: host.latencyMilliseconds,
                hasLoaded: host.hasLoaded,
                available: host.available,
                reason: host.reason,
                projects: group(host.agents, repos: host.repos),
                connection: host.connection
            )
        }
        return HomeLayout(needsYou: needsYou, computers: computers)
    }

    // Identical waiting rows collapse into one; everything else stays a row
    // of its own. Groups keep the order of first appearance so a stack
    // never moves as its members change.
    static func waitingGroups(_ agents: [AgentSummary], askingLine: (AgentSummary) -> String?) -> [WaitingGroup] {
        var order: [String] = []
        var members: [String: [AgentSummary]] = [:]
        var asking: [String: String?] = [:]
        for agent in agents {
            let line = askingLine(agent)
            let key = [agent.hostId, agent.agent, agent.secondaryIdentity ?? agent.projectName, line ?? ""].joined(separator: "|")
            if members[key] == nil {
                order.append(key)
                asking[key] = line
            }
            members[key, default: []].append(agent)
        }
        return order.map { WaitingGroup(key: $0, agents: members[$0] ?? [], askingLine: asking[$0] ?? nil) }
    }

    // Projects by name; agents inside a project keep the host's order. An
    // agent whose cwd sits under a known worktree files under that
    // repository's card, in that worktree's group — an agent's cwd is
    // routinely *inside* a worktree (this repo's own layout: host and iOS
    // agents each in a subfolder), so containment, not equality, is the
    // match, and the longest containing worktree wins. Everything else
    // groups by folder as before. A repository appears only once an agent
    // lives somewhere in it — the home is about work, not every clone on
    // the disk — but then every worktree it has is shown, agents or not.
    // The order is deterministic and does not depend on status, so a
    // project never jumps around the screen as its agents start and finish
    // — the header's count says what is running.
    static func group(_ agents: [AgentSummary], repos: [RepoInfo] = []) -> [HomeProject] {
        var order: [String] = []
        var folderAgents: [String: [AgentSummary]] = [:]
        var repoOf: [String: RepoInfo] = [:]
        var worktreeAgents: [String: [AgentSummary]] = [:]

        for agent in agents {
            let path = projectPath(of: agent.cwd)
            if let (repo, worktree) = repoAndWorktree(containing: path, in: repos) {
                let key = projectPath(of: repo.root)
                if repoOf[key] == nil {
                    order.append(key)
                    repoOf[key] = repo
                }
                worktreeAgents[comparisonKey(worktree.path), default: []].append(agent)
            } else {
                if folderAgents[path] == nil { order.append(path) }
                folderAgents[path, default: []].append(agent)
            }
        }

        return order
            .map { key in
                if let repo = repoOf[key] {
                    return HomeProject(
                        path: key,
                        name: repo.name,
                        needsYou: [],
                        active: [],
                        recent: [],
                        worktrees: repo.worktrees.map { info in
                            let members = worktreeAgents[comparisonKey(info.path)] ?? []
                            return HomeWorktree(
                                info: info,
                                needsYou: members.filter { $0.homeSection == .needsYou },
                                active: members.filter { $0.homeSection == .active },
                                recent: members.filter { $0.homeSection == .recent }
                            )
                        }
                    )
                }
                let members = folderAgents[key] ?? []
                return HomeProject(
                    path: key,
                    name: projectName(of: key),
                    needsYou: members.filter { $0.homeSection == .needsYou },
                    active: members.filter { $0.homeSection == .active },
                    recent: members.filter { $0.homeSection == .recent },
                    worktrees: []
                )
            }
            .sorted { lhs, rhs in
                let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if byName != .orderedSame { return byName == .orderedAscending }
                return lhs.path < rhs.path
            }
    }

    // The repository and worktree a folder lives under, or nil. Longest
    // containing worktree path wins, so a nested worktree beats the one it
    // was born from whenever both are candidates.
    static func repoAndWorktree(containing path: String, in repos: [RepoInfo]) -> (RepoInfo, WorktreeInfo)? {
        let candidate = comparisonKey(path)
        var best: (RepoInfo, WorktreeInfo)?
        var bestLength = -1
        for repo in repos {
            for worktree in repo.worktrees {
                let root = comparisonKey(worktree.path)
                guard candidate == root || candidate.hasPrefix(root + "/") else { continue }
                if root.count > bestLength {
                    best = (repo, worktree)
                    bestLength = root.count
                }
            }
        }
        return best
    }

    // Paths are only ever *compared* through this key, never displayed from
    // it: the host's rule (`projects.ts`) — macOS filesystems are normally
    // case-insensitive and store names in a different Unicode form than a
    // keyboard emits, so `~/projects/Tavi` typed into the picker and
    // `~/Projects/tavi` from `git worktree list` are one folder.
    static func comparisonKey(_ path: String) -> String {
        projectPath(of: path).precomposedStringWithCanonicalMapping.lowercased()
    }

    static func projectPath(of cwd: String) -> String {
        var trimmed = cwd.trimmingCharacters(in: .whitespaces)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    // The folder's own name. The home directory is "Home", not the user's
    // login name; an empty path (a host that reported nothing) says so
    // rather than resolving against the app's working directory.
    static func projectName(of path: String) -> String {
        let path = projectPath(of: path)
        guard !path.isEmpty else { return "Unknown folder" }
        if path.abbreviatingHomeDirectory == "~" { return "Home" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty || name == "/" ? path : name
    }

    // What to call the paired computer: the name it gave when pairing, else
    // its address — the first DNS label when there is one, the whole thing
    // for an IP literal or a bare host typed into the dev form. Never empty:
    // the header is a landmark, not decoration.
    static func computerName(pairedName: String?, hostText: String) -> String {
        if let pairedName, !pairedName.trimmingCharacters(in: .whitespaces).isEmpty { return pairedName }
        let address = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URL(string: address)?.host()
            ?? address.split(separator: "/").first.map(String.init)
            ?? ""
        guard !host.isEmpty else { return "Paired computer" }
        let firstLabel = host.split(separator: ".").first.map(String.init) ?? host
        let isNumeric = !firstLabel.isEmpty && firstLabel.allSatisfy(\.isNumber)
        return isNumeric || host.contains(":") ? host : firstLabel
    }
}

extension String {
    // The path with the home prefix folded to "~" — the phone doesn't know
    // the host's home, so this is a display heuristic only.
    var abbreviatingHomeDirectory: String {
        replacingOccurrences(of: "^/(?:Users|home)/[^/]+", with: "~", options: .regularExpression)
    }
}
