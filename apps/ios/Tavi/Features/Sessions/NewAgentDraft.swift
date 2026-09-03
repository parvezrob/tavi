import Foundation
import Observation

// Everything the New Agent sheet holds while it is open: which computer,
// which agent, where it starts, and what the host has said about it so
// far. One object rather than a screenful of flat state, so the three
// questions can be three views (#100).
@MainActor
@Observable
final class NewAgentDraft {
    var phase: Phase
    // The computer the agent will start on; chosen up front when there is
    // a choice, implied when there is one computer.
    var chosenHostId: String?
    var agentKind: String?
    var selectedPath: String?
    var query = ""
    var customPath = ""
    var inFlight = false
    var failure: String?
    var pendingOutsideRoots: String?
    // Where the agent starts (#75): an existing folder, or a worktree this
    // sheet creates first. Worktree mode needs a repository (pre-filled
    // when opened from a card's "New worktree" row), a base, and a branch.
    var whereMode: WhereMode
    var whereLocked: Bool
    var worktreeRepo: RepoInfo?
    var worktreeBase: String?
    var worktreeBranch = ""
    var repos: [RepoInfo] = []
    var issues: [IssueSummary] = []
    var issuesNote: String?
    // A worktree this sheet already made, so a retry after the agent
    // failed to start does not hit "branch exists" (#81 review).
    var createdWorktree: CreatedWorktree?
    // The outside-roots alert serves both modes; this says which one asked.
    var pendingOutsideRootsIsWorktree = false

    enum WhereMode: String, CaseIterable, Identifiable {
        case folder, worktree
        var id: String { rawValue }
        var label: String { self == .folder ? "A folder" : "A new worktree" }
    }

    enum Phase: Equatable {
        case chooseComputer
        case loading
        case catalog(ProjectCatalog)
        case failed(String)
    }

    init(computers: [HostFleet.Entry], startingIn: (hostId: String, path: String)?, startMode: WhereMode) {
        let hostId = startingIn?.hostId ?? (computers.count == 1 ? computers[0].id : nil)
        chosenHostId = hostId
        phase = hostId == nil ? .chooseComputer : .loading
        selectedPath = startingIn?.path
        whereMode = startingIn == nil ? .folder : startMode
        // "Start an agent here" already knows the place: say it as one
        // row instead of a list with a checkmark buried in it (owner,
        // 2026-09-03). "Change" brings the list back.
        whereLocked = startingIn != nil && startMode == .folder
    }
}
