import Foundation

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

extension AgentSummary {
    // Every target is host + pane (#50), so the directory stamps its
    // computer on every agent it hands on.
    func stamped(hostId: String) -> AgentSummary {
        var stamped = self
        stamped.hostId = hostId
        return stamped
    }
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
