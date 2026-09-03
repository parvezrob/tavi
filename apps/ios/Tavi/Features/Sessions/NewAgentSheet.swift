import SwiftUI

// Start an agent in a folder you picked, never in the host's home directory
// (#24). The sheet asks two questions — which agent, and where — and the
// second one has no default: Create stays disabled until a folder is chosen.
// With more than one computer paired it asks a question before those:
// which computer (#50) — folders and agent kinds belong to one machine.
// The host decides whether a location is ordinary or needs a second look, so
// a folder outside its project roots comes back as a confirmation prompt
// rather than an error.
struct NewAgentSheet: View {
    let computers: [HostFleet.Entry]
    // Called after the sheet has asked to dismiss: the home opens the new
    // pane's terminal (#67) so you land in what you just created.
    let onCreated: (AgentTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    // Remembered across sheets: the kind you launched last is what you most
    // likely want next. Validated against the host's installed list on load.
    @AppStorage("tavi.newAgent.kind") private var rememberedKind = "claude"
    @State private var draft: NewAgentDraft
    private let startingIn: (hostId: String, path: String)?

    // `startingIn`: a folder chosen before the sheet opened — the home card's
    // "New worktree" row (#74) names its folder and computer, so the sheet
    // skips both questions. Until #73 part 2 lands it starts an agent there
    // rather than creating a worktree.
    // `startMode`: a card's "New worktree" row means a worktree (`load()`
    // finds the repository for the folder); a worktree's "Start an agent
    // here" means that folder as it is.
    init(
        computers: [HostFleet.Entry],
        startingIn: (hostId: String, path: String)? = nil,
        startMode: NewAgentDraft.WhereMode = .worktree,
        onCreated: @escaping (AgentTarget) -> Void
    ) {
        self.computers = computers
        self.onCreated = onCreated
        self.startingIn = startingIn
        _draft = State(initialValue: NewAgentDraft(computers: computers, startingIn: startingIn, startMode: startMode))
    }

    private var canCreate: Bool {
        guard !draft.inFlight, draft.agentKind != nil, directory != nil else { return false }
        switch draft.whereMode {
        case .folder: return draft.selectedPath != nil
        case .worktree: return draft.worktreeRepo != nil && !draft.worktreeBranch.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var chosen: HostFleet.Entry? {
        computers.first { $0.id == draft.chosenHostId }
    }

    private var directory: AgentDirectory? { chosen?.directory }

    // "your Mac" only when we do not know better: the name the computer
    // gave when pairing is what the person recognizes.
    private var computerName: String { chosen?.host.displayName ?? "your computer" }

    var body: some View {
        NavigationStack {
            content
                .background(TaviTheme.canvas.ignoresSafeArea())
                .navigationTitle("New Agent")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(draft.whereMode == .worktree ? "Create and start" : "Create") {
                            // Disable before the task starts: two taps inside
                            // one frame would otherwise create two agents.
                            guard canCreate else { return }
                            draft.inFlight = true
                            Task { await create(allowOutsideRoots: false) }
                        }
                        .disabled(!canCreate)
                        .accessibilityIdentifier("newAgent.create")
                    }
                }
        }
        .task { await load() }
        // A computer removed while this sheet is open (Settings, or a
        // revocation) must not leave its folders on screen: back to the
        // question, or straight on if one computer remains.
        .onChange(of: computers.map(\.id)) { _, ids in
            guard let chosenHostId = draft.chosenHostId, !ids.contains(chosenHostId) else { return }
            draft.chosenHostId = ids.count == 1 ? ids[0] : nil
            draft.selectedPath = nil
            draft.failure = nil
            Task { await load() }
        }
        .alert(
            "Start outside your project folders?",
            isPresented: Binding(
                get: { draft.pendingOutsideRoots != nil },
                set: { if !$0 { draft.pendingOutsideRoots = nil } }
            ),
            presenting: draft.pendingOutsideRoots
        ) { path in
            Button("Cancel", role: .cancel) { draft.pendingOutsideRoots = nil }
                .accessibilityIdentifier("newAgent.outsideRoots.cancel")
            Button(draft.pendingOutsideRootsIsWorktree ? "Create there" : "Start here", role: .destructive) {
                draft.pendingOutsideRoots = nil
                draft.inFlight = true
                if draft.pendingOutsideRootsIsWorktree {
                    Task { await create(allowOutsideRoots: true) }
                } else {
                    Task { await create(allowOutsideRoots: true, path: path) }
                }
            }
            .accessibilityIdentifier("newAgent.outsideRoots.confirm")
        } message: { path in
            if draft.pendingOutsideRootsIsWorktree {
                // The host's own sentence names where the worktree would go.
                Text(path)
            } else {
                Text("\(path) is not inside the project folders configured on \(computerName). The agent will be able to read and change files there.")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch draft.phase {
        case .chooseComputer:
            ComputerPicker(computers: computers) { entry in
                draft.chosenHostId = entry.id
                Task { await load() }
            }

        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Reading the projects on \(computerName)…")
                    .font(.callout)
                    .foregroundStyle(TaviTheme.textSecondary)
                chooseAnotherComputerButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("newAgent.loading")

        case let .failed(message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(TaviTheme.statusBlocked)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(TaviTheme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("newAgent.retry")
                // A sleeping computer must not be a dead end (#50).
                chooseAnotherComputerButton
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("newAgent.failed")

        case let .catalog(catalog):
            NewAgentForm(
                draft: draft,
                catalog: catalog,
                computerCount: computers.count,
                computerName: computerName,
                startingIn: startingIn,
                sourceControl: directory?.sourceControlClient,
                rememberedKind: $rememberedKind,
                onChangeComputer: chooseAnotherComputer
            )
        }
    }

    @ViewBuilder
    private var chooseAnotherComputerButton: some View {
        if computers.count > 1 {
            Button("Choose another computer", action: chooseAnotherComputer)
                .font(.footnote)
                .accessibilityIdentifier("newAgent.chooseAnotherComputer")
        }
    }

    private func chooseAnotherComputer() {
        draft.phase = .chooseComputer
        draft.selectedPath = nil
        draft.failure = nil
    }

    private func load() async {
        guard let directory else {
            draft.phase = .chooseComputer
            return
        }
        draft.phase = .loading
        switch await directory.fetchProjects() {
        case let .catalog(catalog):
            draft.agentKind = ProjectPicker.defaultAgentKind(in: catalog.agents, preferring: rememberedKind)
            await loadRepos(from: directory)
            draft.phase = .catalog(catalog)
        case let .failure(message): draft.phase = .failed(message)
        }
    }

    // The repositories worktree mode can make one in: the directory's last
    // poll, or one fetch when it has none yet. Opened from a card, the
    // repository containing that folder is chosen up front.
    private func loadRepos(from directory: AgentDirectory) async {
        var list = directory.repos
        if list.isEmpty, case let .repos(fetched) = await directory.fetchRepos() { list = fetched }
        draft.repos = list
        if draft.worktreeRepo == nil, let startingIn, let (repo, _) = HomeGrouping.repoAndWorktree(containing: HomeGrouping.projectPath(of: startingIn.path), in: list) {
            draft.worktreeRepo = repo
            draft.worktreeBase = repo.defaultBranch ?? repo.branches.first
            // Folder mode stays folder mode: the repository is only
            // remembered in case the person switches.
        } else if draft.worktreeRepo == nil, draft.whereMode == .worktree {
            // Asked for a worktree from a folder no repo claims: fall back
            // to a plain folder rather than a mode with nothing to pick.
            draft.whereMode = list.isEmpty ? .folder : .worktree
        }
    }

    private func create(allowOutsideRoots: Bool, path: String? = nil) async {
        guard let agentKind = draft.agentKind, let directory else {
            draft.inFlight = false
            return
        }
        draft.failure = nil
        draft.inFlight = true
        defer { draft.inFlight = false }

        var cwd: String
        if draft.whereMode == .worktree, path == nil, let made = draft.createdWorktree, made.branch == draft.worktreeBranch.trimmingCharacters(in: .whitespaces) {
            // The worktree exists from a try whose agent failed to start:
            // go straight to the agent, never a second `worktree add`.
            cwd = made.path
        } else if draft.whereMode == .worktree, path == nil {
            // Make the worktree first; its folder is then where the agent
            // starts. The folder the host just made is inside the roots
            // whenever the worktree was, so the second call needs no
            // confirmation of its own.
            guard let repo = draft.worktreeRepo else { return }
            let branch = draft.worktreeBranch.trimmingCharacters(in: .whitespaces)
            switch await directory.createWorktree(repo: repo.root, branch: branch, base: draft.worktreeBase, allowOutsideRoots: allowOutsideRoots) {
            case let .created(worktree):
                draft.createdWorktree = worktree
                cwd = worktree.path
                // The home files agents under the worktrees it knows; the
                // repo poll is 30 s, so learn about this one now, before the
                // agent's row arrives on the feed (owner, 2026-09-02: the new
                // worktree sat as a plain folder card until the next poll).
                await directory.refreshRepos()
            case .needsOutsideRootsConfirmation where allowOutsideRoots:
                draft.failure = "The host would not create the worktree even after confirmation."
                return
            case let .needsOutsideRootsConfirmation(message):
                draft.pendingOutsideRootsIsWorktree = true
                draft.pendingOutsideRoots = message
                return
            case let .failure(message):
                draft.failure = message
                return
            }
        } else {
            guard let chosen = path ?? draft.selectedPath else { return }
            cwd = chosen
            draft.pendingOutsideRootsIsWorktree = false
        }

        switch await directory.createTab(agent: agentKind, cwd: cwd, allowOutsideRoots: allowOutsideRoots || draft.whereMode == .worktree) {
        case let .created(paneId, _):
            // The row arrives on the live snapshot feed like any other; the
            // terminal opens right away on the pane the host named.
            dismiss()
            onCreated(AgentTarget(hostId: directory.hostId, paneId: paneId))
        case .needsOutsideRootsConfirmation where allowOutsideRoots:
            // The host asked to confirm a location this call already
            // confirmed. Never re-raise the alert: that is a loop with no
            // exit but Cancel.
            draft.failure = "The host would not start an agent in \(cwd) even after confirmation."
        case .needsOutsideRootsConfirmation:
            draft.pendingOutsideRoots = cwd
        case let .failure(message):
            draft.failure = draft.createdWorktree != nil && draft.whereMode == .worktree
                ? "\(message) The worktree was created at \(cwd); Create again starts the agent there."
                : message
        }
    }
}
