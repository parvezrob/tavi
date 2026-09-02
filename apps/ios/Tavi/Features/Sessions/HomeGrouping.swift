import Foundation

// The home reads computer → project → agents (#26, #50). A project is the
// folder an agent lives in — its cwd, nothing to name or maintain — and a
// computer is the paired host that reported it. Every paired computer gets
// its own group with its own connection health, in pairing order, so a
// host that is asleep is a quiet "Offline" header and never a blank home.
//
// What needs the user is deliberately *not* rendered inside the groups: a
// waiting agent must never sit under a project the eye has skipped, so
// needs-you stays a flat list above everything (PRD §7.1). The project it
// belongs to still knows about it — the header counts it — so a folder does
// not vanish and reappear as its agent blocks and resumes.
struct HomeProject: Identifiable, Equatable {
    // The cwd as the host reported it, trailing slashes trimmed. Two agents
    // in the same folder share a project; the phone does not try to be
    // cleverer about paths than the host that produced them.
    let path: String
    let name: String
    // Rendered flat above the groups, counted here.
    let needsYou: [AgentSummary]
    let active: [AgentSummary]
    let recent: [AgentSummary]
    // Set when this project's folder is a git worktree (#59a) — the same
    // host's GET /api/repos, matched by path. nil for an ordinary folder,
    // or one the host hasn't reported worktree state for yet.
    let worktree: WorktreeInfo?

    var id: String { path }
    var abbreviatedPath: String { path.abbreviatingHomeDirectory }
    var agentCount: Int { needsYou.count + active.count + recent.count }
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

    var agentCount: Int { projects.reduce(0) { $0 + $1.agentCount } }
    // Reachable, feed usable, still paired — nothing to explain.
    var isQuietlyIdle: Bool { hasLoaded && available && health != .revoked }
    var waitingCount: Int { projects.reduce(0) { $0 + $1.needsYou.count } }

    // "Live · 40 ms · 8 agents · 5 waiting" — the computer in one line,
    // for its chip's spoken value, the Computers menu, and its sheet.
    var summary: String {
        var parts = [health.label(latencyMilliseconds: latencyMilliseconds)]
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
    // Every worktree this host's GET /api/repos reported (#59a), flattened
    // across repos — grouping only needs to match one against a project's
    // path, not which repo it belongs to.
    let worktrees: [WorktreeInfo]

    init(
        id: String,
        name: String,
        agents: [AgentSummary],
        health: HostHealth = .live,
        latencyMilliseconds: Int? = nil,
        hasLoaded: Bool = true,
        available: Bool = true,
        reason: String? = nil,
        worktrees: [WorktreeInfo] = []
    ) {
        self.id = id
        self.name = name
        self.agents = agents
        self.health = health
        self.latencyMilliseconds = latencyMilliseconds
        self.hasLoaded = hasLoaded
        self.available = available
        self.reason = reason
        self.worktrees = worktrees
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
                projects: group(host.agents, worktrees: host.worktrees)
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

    // Projects by name; agents inside a project keep the host's order. The
    // order is deterministic and does not depend on status, so a project
    // never jumps around the screen as its agents start and finish — the
    // header's count says what is running.
    static func group(_ agents: [AgentSummary], worktrees: [WorktreeInfo] = []) -> [HomeProject] {
        var order: [String] = []
        var members: [String: [AgentSummary]] = [:]

        for agent in agents {
            let path = projectPath(of: agent.cwd)
            if members[path] == nil { order.append(path) }
            members[path, default: []].append(agent)
        }
        return order
            .map { path in
                let agents = members[path] ?? []
                return HomeProject(
                    path: path,
                    name: projectName(of: path),
                    needsYou: agents.filter { $0.homeSection == .needsYou },
                    active: agents.filter { $0.homeSection == .active },
                    recent: agents.filter { $0.homeSection == .recent },
                    worktree: worktree(containing: path, in: worktrees)
                )
            }
            .sorted { lhs, rhs in
                let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if byName != .orderedSame { return byName == .orderedAscending }
                return lhs.path < rhs.path
            }
    }

    // The worktree a project's folder lives under, or nil. An agent's cwd is
    // routinely *inside* a worktree rather than at its root — this repo's
    // own layout, host and iOS agents each in their own subfolder, is the
    // ordinary case — so containment, not equality, is the match; the
    // longest (most specific) containing worktree wins when more than one
    // qualifies, so a linked worktree beats the main one it was born from
    // whenever both are somehow candidates.
    static func worktree(containing path: String, in worktrees: [WorktreeInfo]) -> WorktreeInfo? {
        worktrees
            .filter { worktree in
                let root = projectPath(of: worktree.path)
                return path == root || path.hasPrefix(root + "/")
            }
            .max { projectPath(of: $0.path).count < projectPath(of: $1.path).count }
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
