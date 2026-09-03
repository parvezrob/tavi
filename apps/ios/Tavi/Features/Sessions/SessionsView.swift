import SwiftUI

// Sessions home (ROADMAP Phase C): what needs the user leads, running work
// follows, finished work drops to a quiet recent list. The mockups in
// docs/assets are reference; the binding contract is PRD §7.1 and the
// navigation map. The home reads computer → project → agents (#26), one
// group per paired computer with its own connection health (#50), and
// every terminal is one herdr agent pane on one host (#53).
struct SessionsView: View {
    @Environment(\.scenePhase) private var scenePhase
    // Every paired computer and its live mirror (#50). The fleet is the
    // only writer of the host list and the Keychain credentials.
    @State private var fleet = HostFleet()
    @State private var bootstrapped = false
    @State private var draftHost = ""
    @State private var draftToken = ""
    @State private var showingHostForm = false
    @State private var showingPairing = false
    @State private var showingSettings = false
    // "Pair another computer" from inside Settings must wait for the
    // Settings sheet to finish dismissing before the pairing sheet can
    // present; flipping both flags in one turn silently drops the second.
    @State private var pairingAfterSettings = false
    @State private var showingNewAgent = false
    // The agent the New Agent sheet just created (#67); opened once the
    // sheet has finished dismissing, so the push is not fighting the sheet.
    @State private var createdAgent: AgentTarget?
    @State private var decisionAgent: DecisionTarget?
    // A revoked computer's Remove asks first: it wipes a credential.
    @State private var removingHostId: String?
    @State private var terminalController = TerminalSessionController()
    @State private var terminalIsPresented = false
    // The computer the open terminal is attached to (#50): its directory
    // backs the terminal's identity header, rename, and prompt delivery.
    @State private var terminalHostId: String?
    // The chip that is selected: nil is "All". A filter, never a
    // hierarchy — sessions stay one list by state (owner call 2026-09-02
    // after the first two-computer screen buried the second computer).
    @State private var selectedHostId: String?
    // The computer whose sheet was opened from its chip.
    @State private var chipSheet: HostFleet.Entry?
    // Stacks of indistinguishable waiting agents the user opened in place.
    @State private var expandedWaitingStacks: Set<String> = []
    // Files for one agent from the home (#25): a long-press on its row.
    @State private var filesAgent: AgentSummary?
    @State private var previewAgent: AgentSummary?
    // Grouping re-sorts and re-scans every card, and the home reads it
    // twice per redraw: it is regrouped only when the computers' own state
    // changes (#68 phone 4).
    @State private var layouts = HomeLayoutCache()

    var body: some View {
        NavigationStack {
            ScrollView {
                // Deliberately not lazy: the home holds a handful of rows,
                // and LazyVStack's subview caching served a stale card (old
                // status pill) after a row moved sections.
                VStack(alignment: .leading, spacing: 20) {
                    homeContent
                }
                .padding(.horizontal, TaviTheme.Spacing.screen)
                .padding(.top, 2)
                .padding(.bottom, 28)
            }
            .background(TaviTheme.canvas.ignoresSafeArea())
            .navigationTitle("Tavi")
            .accessibilityIdentifier("sessions.list")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New agent", systemImage: "plus") {
                        showingNewAgent = true
                    }
                    .disabled(!fleet.isConfigured)
                    .accessibilityIdentifier("sessions.newAgentTab")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Pairing is the way in (#45). The typed host/token form
                    // survives only in DEBUG for simulator and UI-test runs.
                    Menu {
                        // Paired computers live under Settings → Security (#51).
                        Button("Settings", systemImage: "gearshape") { showingSettings = true }
                            .accessibilityIdentifier("sessions.settings")
                        // Adds a computer; the ones already paired stay (#50).
                        Button("Pair a computer", systemImage: "qrcode.viewfinder") { showingPairing = true }
                            .accessibilityIdentifier("sessions.pair")
                        if !fleet.hosts.isEmpty {
                            // Which computers are paired, one tap from the
                            // home, with their health (#50).
                            Section("Paired computers") {
                                ForEach(homeLayout.computers) { computer in
                                    Button {
                                        chipSheet = fleet.entries.first { $0.id == computer.id }
                                    } label: {
                                        Label {
                                            Text(computer.name)
                                            Text(computer.summary)
                                        } icon: {
                                            Image(systemName: "desktopcomputer")
                                        }
                                    }
                                }
                            }
                        }
                        #if DEBUG
                            Button("Enter host and token (dev)", systemImage: "keyboard") {
                                draftHost = ""
                                draftToken = ""
                                showingHostForm = true
                            }
                            .accessibilityIdentifier("sessions.hostSettings")
                        #endif
                    } label: {
                        Label("Computers", systemImage: "desktopcomputer")
                    }
                    .accessibilityIdentifier("sessions.hostMenu")
                }
            }
            .navigationDestination(isPresented: $terminalIsPresented) {
                TerminalSessionView(
                    controller: terminalController,
                    agentDirectory: terminalHostId.flatMap { fleet.directory(for: $0) },
                    computerName: terminalHostId.flatMap { computerLabel(for: $0) },
                    jumpSources: jumpSources,
                    onSelectAgent: { agent in openAgent(agent) }
                )
            }
            .sheet(isPresented: $showingNewAgent, onDismiss: {
                newWorktreeIn = nil
                newAgentStartMode = .worktree
                guard let created = createdAgent else { return }
                createdAgent = nil
                openAgent(hostId: created.hostId, paneID: created.paneId)
            }) {
                NewAgentSheet(computers: fleet.entries, startingIn: newWorktreeIn, startMode: newAgentStartMode) { created in
                    createdAgent = created
                }
            }
            .sheet(isPresented: $showingPairing) {
                PairingFlowView { endpoint, grant in
                    // Pairing a computer already on the list (same
                    // fingerprint) replaces its entry; anything else is
                    // added beside the others.
                    fleet.add(.paired(endpoint: endpoint, grant: grant), credential: grant.credential)
                }
            }
            .sheet(isPresented: $showingSettings, onDismiss: {
                if pairingAfterSettings {
                    pairingAfterSettings = false
                    showingPairing = true
                }
            }) {
                SettingsView(
                    fleet: fleet,
                    onForget: { hostId in fleet.remove(hostId: hostId) },
                    onPairAnother: {
                        pairingAfterSettings = true
                        showingSettings = false
                    }
                )
            }
            .sheet(isPresented: $showingHostForm) {
                HostTokenForm(
                    address: $draftHost,
                    token: $draftToken,
                    onDismiss: { showingHostForm = false },
                    onSave: { address, token in fleet.add(.typed(address: address), credential: token) }
                )
                .presentationDetents([.medium])
            }
            .sheet(item: $chipSheet) { entry in
                ManageAccessView(
                    host: entry.host,
                    directory: entry.directory,
                    onForget: { fleet.remove(hostId: entry.id) },
                    onRename: { fleet.rename(hostId: entry.id, alias: $0) }
                )
            }
            // A removed computer cannot stay selected or on a sheet.
            .onChange(of: fleet.hosts.map(\.id)) { _, ids in
                if let selectedHostId, !ids.contains(selectedHostId) { self.selectedHostId = nil }
                if let chipSheet, !ids.contains(chipSheet.id) { self.chipSheet = nil }
            }
            // A worktree's "Start an agent here" opens the New Agent sheet
            // on that folder once this sheet has gone (one sheet at a time).
            .sheet(item: $sourceControlTarget, onDismiss: {
                if let pending = pendingAgentFolder {
                    newWorktreeIn = pending
                    newAgentStartMode = .folder
                    pendingAgentFolder = nil
                    showingNewAgent = true
                }
            }) { target in
                SourceControlSheet(
                    worktree: target.worktree,
                    repoName: target.repoName,
                    client: fleet.directory(for: target.hostId)?.sourceControlClient,
                    filesClient: fleet.directory(for: target.hostId)?.filesClient,
                    computerName: computerLabel(for: target.hostId),
                    onRemoved: { _ in
                        sourceControlTarget = nil
                        Task { await fleet.directory(for: target.hostId)?.refreshRepos() }
                    },
                    onStartAgent: {
                        pendingAgentFolder = (hostId: target.hostId, path: target.worktree.info.path)
                        sourceControlTarget = nil
                    }
                )
            }
            .sheet(item: $filesAgent) { agent in
                FilesSheet(
                    agent: agent,
                    client: fleet.directory(for: agent.hostId)?.filesClient,
                    computerName: computerLabel(for: agent.hostId),
                    transcript: nil,
                    initialTab: .changed
                )
            }
            .sheet(item: $previewAgent) { agent in
                PreviewSheet(
                    agent: agent,
                    client: fleet.directory(for: agent.hostId)?.previewClient,
                    computerName: computerLabel(for: agent.hostId),
                    transcript: nil
                )
            }
            .sheet(item: $decisionAgent) { target in
                // The decision goes to the computer the agent lives on; the
                // tap site checked that computer is still paired, and this
                // else only stands in for a removal that raced the sheet.
                if let directory = fleet.directory(for: target.agent.hostId) {
                    PermissionDecisionSheet(
                        agent: target.agent,
                        directory: directory,
                        computerName: computerLabel(for: target.agent.hostId),
                        onOpenTerminal: { openAgent(target.agent) }
                    )
                    .presentationDetents([.medium, .large])
                } else {
                    Text("This computer is no longer paired.")
                        .font(.callout)
                        .foregroundStyle(TaviTheme.textSecondary)
                        .padding(24)
                        .presentationDetents([.medium])
                }
            }
            .confirmationDialog(
                "Remove this computer from Tavi?",
                isPresented: Binding(
                    get: { removingHostId != nil },
                    set: { if !$0 { removingHostId = nil } }
                ),
                titleVisibility: .visible,
                presenting: removingHostId
            ) { hostId in
                Button("Remove", role: .destructive) {
                    fleet.remove(hostId: hostId)
                    removingHostId = nil
                }
                Button("Cancel", role: .cancel) { removingHostId = nil }
            } message: { hostId in
                Text("\(computerLabel(for: hostId) ?? "It") stays paired on its own side until you revoke this iPhone there. You can pair it again any time.")
            }
            .task {
                // Once per home, not once per visit: the root of a
                // NavigationStack appears again every time a terminal pops
                // back to it, and reloading the fleet there rebuilt every
                // computer's directory per trip (2026-09-02 memory check).
                guard !bootstrapped else { return }
                bootstrapped = true
                fleet.load()
                #if DEBUG
                    // UI tests must not inherit a connection persisted by an
                    // earlier run on the same simulator.
                    if ProcessInfo.processInfo.environment["TAVI_DEV_RESET"] == "1" {
                        fleet.removeAll()
                        TerminalFontPreference.reset()
                        TerminalViewportRecord.clear()
                        UserDefaults.standard.removeObject(forKey: AppLock.storageKey)
                    }
                #endif
                seedFromDevelopmentEnvironmentIfNeeded()
                #if DEBUG
                    // Scripted font-size runs (#51): the terminal preference is
                    // in the app container, unreachable from simctl, so live
                    // verification seeds it here like the other TAVI_DEV_ keys.
                    if let raw = ProcessInfo.processInfo.environment["TAVI_DEV_FONT_SIZE"],
                       let size = Double(raw) {
                        TerminalFontPreference.save(size)
                    }
                #endif
                #if DEBUG
                    // Scripted development runs and the terminal UI tests jump
                    // straight into one agent's terminal without a tap. The
                    // pane is attached by id on the first paired computer
                    // because the agent list may not have loaded yet; a pane
                    // that does not exist fails honestly on the terminal itself.
                    if let paneID = TerminalDevelopmentBootstrap.launchEnvironment().agentPaneID,
                       let hostId = fleet.hosts.first?.id {
                        openAgent(hostId: hostId, paneID: paneID)
                    }
                #endif
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    terminalController.sceneDidBecomeActive()
                    fleet.start()
                case .background:
                    terminalController.sceneWillResignActive()
                    fleet.stop()
                case .inactive:
                    break
                @unknown default:
                    terminalController.sceneWillResignActive()
                    fleet.stop()
                }
            }
        }
    }

    // MARK: - Home sections

    @ViewBuilder
    private var homeContent: some View {
        if !fleet.isConfigured {
            // The first impression owns the middle of the screen, not the
            // top edge of an otherwise empty page (#54).
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                NoHostCard { showingPairing = true }
                Spacer(minLength: 0)
            }
            .containerRelativeFrame(.vertical) { length, _ in length * 0.7 }
        } else {
            let layout = homeLayout
            let shown = layout.computers.filter { selectedHostId == nil || $0.id == selectedHostId }
            let severalShown = shown.count > 1
            let needsYou = layout.needsYou.filter { agent in shown.contains { $0.id == agent.hostId } }
            let projects = shown.flatMap { computer in
                // A folder whose every agent is waiting above has nothing to
                // show here; a header pointing upward was noise (owner,
                // 2026-09-02 — supersedes the #26 "keeps its header" rule).
                computer.projects
                    .filter(\.hasRows)
                    .map { HomeProjectItem(computer: computer, project: $0) }
            }

            ComputerStrip(computers: layout.computers, selectedHostId: $selectedHostId) { computer in
                chipSheet = fleet.entries.first { $0.id == computer.id }
            }

            // A computer in trouble says so once, right under the strip,
            // whatever else is on screen; its last known cards stay below.
            ForEach(shown.filter { $0.hasLoaded && ($0.health == .stale || $0.health == .offline) }) { computer in
                LastKnownBanner(computer: computer)
            }

            if !needsYou.isEmpty {
                NeedsYouSection(
                    agents: needsYou,
                    computerName: { severalShown ? computerName(for: $0.hostId) : nil },
                    preview: { fleet.directory(for: $0.hostId)?.previews[$0.id] },
                    observedAt: { fleet.directory(for: $0.hostId)?.statusObservedAt[$0.id] },
                    expandedStacks: $expandedWaitingStacks,
                    onSelect: { agent in
                        guard fleet.directory(for: agent.hostId) != nil else { return }
                        decisionAgent = DecisionTarget(agent: agent)
                    }
                )
            }

            // Project → agents (#26), one list across every computer shown
            // (#50): each folder is one card, naming its computer when more
            // than one is on screen. A blocked agent is only in the block
            // above — its folder never repeats it.
            if !projects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Projects")
                    ForEach(projects, id: \.id) { item in
                        ProjectCard(
                            project: item.project,
                            computerName: severalShown ? item.computer.name : nil,
                            preview: { fleet.directory(for: $0.hostId)?.previews[$0.id] },
                            observedAt: { fleet.directory(for: $0.hostId)?.statusObservedAt[$0.id] },
                            onOpen: { openAgent($0) },
                            onShowFiles: { filesAgent = $0 },
                            onShowPreview: { previewAgent = $0 },
                            onNewWorktree: { project in
                                newWorktreeIn = (hostId: item.computer.id, path: project.path)
                                showingNewAgent = true
                            },
                            onOpenWorktree: { worktree in
                                sourceControlTarget = SourceControlTarget(hostId: item.computer.id, repoName: item.project.name, worktree: worktree)
                            }
                        )
                    }
                }
            }

            // Whatever is not projects: a computer that is still connecting,
            // cannot be reached, has no usable feed, or was unpaired — one
            // card each. When every shown computer is simply idle, one line.
            ForEach(shown.filter { $0.projects.isEmpty && !$0.isQuietlyIdle }) { computer in
                ComputerStateCard(
                    computer: computer,
                    onPairAgain: { showingPairing = true },
                    onRemove: { removingHostId = computer.id }
                )
            }
            if !shown.isEmpty, needsYou.isEmpty, shown.allSatisfy({ $0.projects.isEmpty && $0.isQuietlyIdle }) {
                IdleCard(computers: shown) { showingNewAgent = true }
            }
        }
    }

    private func computerName(for hostId: String) -> String? {
        fleet.host(for: hostId)?.displayName
    }

    // A repository card's "New worktree" row (#74) opens the New Agent
    // sheet already pointed at that folder on that computer. Until #73
    // part 2 lands, that starts an agent in the folder rather than
    // creating a worktree.
    @State private var newWorktreeIn: (hostId: String, path: String)?
    @State private var newAgentStartMode: NewAgentDraft.WhereMode = .worktree
    @State private var pendingAgentFolder: (hostId: String, path: String)?
    // A worktree's Source Control sheet (#77), keyed by computer + path
    // since two computers can hold the same path.
    @State private var sourceControlTarget: SourceControlTarget?

    private struct SourceControlTarget: Identifiable {
        let hostId: String
        let repoName: String
        let worktree: HomeWorktree
        var id: String { "\(hostId)|\(worktree.id)" }
    }

    private var homeLayout: HomeLayout {
        layouts.layout(for: homeInputs)
    }

    private var homeInputs: [HomeHostInput] {
        fleet.entries.map { entry in
            HomeHostInput(
                id: entry.host.id,
                name: entry.host.displayName,
                agents: entry.directory.agents,
                health: entry.directory.health,
                latencyMilliseconds: entry.directory.latencyMilliseconds,
                hasLoaded: entry.directory.hasLoaded,
                available: entry.directory.available,
                reason: entry.directory.reason,
                repos: entry.directory.repos,
                connection: entry.directory.connection
            )
        }
    }

    private var jumpSources: [JumpSource] {
        fleet.entries.map { JumpSource(hostId: $0.host.id, name: $0.host.displayName, directory: $0.directory) }
    }

    // The computer's name, only when there is more than one to tell apart
    // (#50); with a single computer the name is noise on every screen.
    private func computerLabel(for hostId: String) -> String? {
        guard fleet.hosts.count > 1 else { return nil }
        return computerName(for: hostId)
    }

    // A folder on a computer: two computers can hold the same path, so the
    // list identity is both.
    private struct HomeProjectItem: Identifiable {
        let computer: HomeComputer
        let project: HomeProject
        var id: String { "\(computer.id)|\(project.id)" }
    }

    // One agent to decide on, keyed by host + pane so two computers'
    // same-numbered panes never share a sheet identity.
    private struct DecisionTarget: Identifiable {
        let agent: AgentSummary
        var id: String { agent.cardIdentity }
    }

    // MARK: - Actions

    private func openAgent(_ agent: AgentSummary) {
        openAgent(hostId: agent.hostId, paneID: agent.id)
    }

    // Every terminal target is host + pane (#50): the pane id alone says
    // nothing about which computer to dial.
    private func openAgent(hostId: String, paneID: String) {
        guard let host = fleet.host(for: hostId) else { return }
        terminalController.stop()
        terminalHostId = hostId
        terminalController.connect(hostText: host.address, paneID: paneID, credential: fleet.credential(for: hostId))
        terminalIsPresented = true
    }

    private func seedFromDevelopmentEnvironmentIfNeeded() {
        // Release builds must never persist an injected credential (#33).
        #if DEBUG
            // TAVI_DEV_HOST takes a comma-separated list so a simulator can show
            // a several-computer home (the same Mac twice is enough to look at
            // the layout); TAVI_DEV_HOST_NAMES names them in the same order.
            let environment = ProcessInfo.processInfo.environment
            if !fleet.isConfigured, let hosts = environment["TAVI_DEV_HOST"], !hosts.isEmpty {
                let addresses = hosts.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let names = (environment["TAVI_DEV_HOST_NAMES"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                for (index, address) in addresses.enumerated() where !address.isEmpty {
                    let host = PairedHost.typed(address: address)
                    fleet.add(host, credential: environment["TAVI_DEV_TOKEN"] ?? "")
                    if index < names.count, !names[index].isEmpty {
                        fleet.rename(hostId: host.id, alias: names[index])
                    }
                }
            }
        #endif
    }
}

// The last grouping and the input it was made from. Deliberately not
// observable, and deliberately not @State + .onChange: measured 2026-09-03,
// that state write cost the home a second body pass per snapshot (30 -> 62
// per minute) to save one regrouping.
@MainActor
final class HomeLayoutCache {
    private var inputs: [HomeHostInput]?
    private var cached = HomeLayout(needsYou: [], computers: [])

    func layout(for inputs: [HomeHostInput]) -> HomeLayout {
        guard inputs != self.inputs else { return cached }
        self.inputs = inputs
        cached = HomeGrouping.layout(hosts: inputs)
        return cached
    }
}

#Preview {
    SessionsView()
}
