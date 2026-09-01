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

    var body: some View {
        NavigationStack {
            ScrollView {
                // Deliberately not lazy: the home holds a handful of rows,
                // and LazyVStack's subview caching served a stale card (old
                // status pill) after a row moved sections.
                VStack(alignment: .leading, spacing: 20) {
                    homeContent
                }
                .padding(.horizontal, 16)
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
            .sheet(isPresented: $showingNewAgent) {
                NewAgentSheet(computers: fleet.entries)
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
                hostForm
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
                noHostCard
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
                    .filter { !$0.active.isEmpty || !$0.recent.isEmpty }
                    .map { HomeProjectItem(computer: computer, project: $0) }
            }

            computerStrip(layout.computers)

            // A computer in trouble says so once, right under the strip,
            // whatever else is on screen; its last known cards stay below.
            ForEach(shown.filter { $0.hasLoaded && ($0.health == .stale || $0.health == .offline) }) { computer in
                lastKnownBanner(computer)
            }

            // Needs-you is flat and first, across every computer and
            // project: a waiting agent never hides under a group. Said
            // once — the header carries the count, the rows carry the
            // agents; there is no banner repeating either (home v3). Row
            // identity includes the status so a section move rebuilds the
            // row instead of reusing a cached one. A row opens the decision
            // sheet (approve/deny without the terminal).
            if !needsYou.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Needs you", count: needsYou.count > 1 ? needsYou.count : nil, countTint: TaviTheme.accent)
                        .accessibilityIdentifier("sessions.needsYou")
                    let groups = HomeGrouping.waitingGroups(needsYou) { agent in
                        NeedsYouRow.askingLine(in: fleet.directory(for: agent.hostId)?.previews[agent.id])
                    }
                    VStack(spacing: 0) {
                        ForEach(groups) { group in
                            if group.isStacked {
                                WaitingStackRow(
                                    group: group,
                                    computerName: severalShown ? computerName(for: group.primary.hostId) : nil,
                                    isExpanded: expandedWaitingStacks.contains(group.key)
                                ) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        if expandedWaitingStacks.remove(group.key) == nil {
                                            expandedWaitingStacks.insert(group.key)
                                        }
                                    }
                                }
                                if expandedWaitingStacks.contains(group.key) {
                                    ForEach(group.agents, id: \.cardIdentity) { agent in
                                        Divider().overlay(TaviTheme.hairline).padding(.leading, 60)
                                        needsYouRow(agent, computerName: nil, primaryOverride: agent.tabLabel ?? agent.id)
                                            .padding(.leading, 16)
                                    }
                                }
                            } else {
                                needsYouRow(group.primary, computerName: severalShown ? computerName(for: group.primary.hostId) : nil, primaryOverride: nil)
                            }
                            if group.id != groups.last?.id {
                                Divider().overlay(TaviTheme.hairline).padding(.leading, 60)
                            }
                        }
                    }
                    .taviCard()
                }
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
                            onShowPreview: { previewAgent = $0 }
                        )
                    }
                }
            }

            // Whatever is not projects: a computer that is still connecting,
            // cannot be reached, has no usable feed, or was unpaired — one
            // card each. When every shown computer is simply idle, one line.
            ForEach(shown.filter { $0.projects.isEmpty && !$0.isQuietlyIdle }) { computer in
                computerStateCard(computer)
            }
            if !shown.isEmpty, needsYou.isEmpty, shown.allSatisfy({ $0.projects.isEmpty && $0.isQuietlyIdle }) {
                idleCard(shown)
            }
        }
    }

    // The host tier: a row of chips — All, then every computer, in pairing
    // order (#50). With one computer, one status pill. Tap filters; a long
    // press opens the computer's sheet (address, round trip, rename, unpair).
    private func computerStrip(_ computers: [HomeComputer]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if computers.count > 1 {
                    AllComputersChip(isSelected: selectedHostId == nil) { selectedHostId = nil }
                }
                ForEach(computers) { computer in
                    ComputerChip(
                        computer: computer,
                        isSelected: computers.count > 1 && selectedHostId == computer.id,
                        showsWaitingCount: computers.count > 1
                    ) {
                        if computers.count > 1 {
                            selectedHostId = selectedHostId == computer.id ? nil : computer.id
                        } else {
                            chipSheet = fleet.entries.first { $0.id == computer.id }
                        }
                    }
                    .contextMenu {
                        Button("About \(computer.name)", systemImage: "info.circle") {
                            chipSheet = fleet.entries.first { $0.id == computer.id }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("sessions.computers")
    }

    @ViewBuilder
    private func computerStateCard(_ computer: HomeComputer) -> some View {
        if computer.health == .revoked {
            revokedCard(computer)
        } else if !computer.hasLoaded {
            if computer.health == .offline {
                offlineCard(computer)
            } else {
                loadingCard(computer)
            }
        } else if !computer.available {
            unavailableCard(computer)
        }
    }

    private func computerName(for hostId: String) -> String? {
        fleet.host(for: hostId)?.displayName
    }

    private var homeLayout: HomeLayout {
        HomeGrouping.layout(hosts: fleet.entries.map { entry in
            HomeHostInput(
                id: entry.host.id,
                name: entry.host.displayName,
                agents: entry.directory.agents,
                health: entry.directory.health,
                latencyMilliseconds: entry.directory.latencyMilliseconds,
                hasLoaded: entry.directory.hasLoaded,
                available: entry.directory.available,
                reason: entry.directory.reason
            )
        })
    }

    private var jumpSources: [JumpSource] {
        fleet.entries.map { JumpSource(hostId: $0.host.id, name: $0.host.displayName, directory: $0.directory) }
    }

    private func needsYouRow(_ agent: AgentSummary, computerName: String?, primaryOverride: String?) -> some View {
        let directory = fleet.directory(for: agent.hostId)
        return NeedsYouRow(
            agent: agent,
            preview: directory?.previews[agent.id],
            observedAt: directory?.statusObservedAt[agent.id],
            computerName: computerName,
            primaryOverride: primaryOverride
        ) {
            guard directory != nil else { return }
            decisionAgent = DecisionTarget(agent: agent)
        }
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

    // MARK: - Empty and degraded states

    // First run leads with the promise, not the absence (#54): what Tavi
    // is for, then the one step, then the trust line that used to hide in
    // the pairing sheet's footer.
    private var noHostCard: some View {
        VStack(spacing: 10) {
            Text("Your agents, in your pocket")
                .font(.title3.weight(.semibold))
                .foregroundStyle(TaviTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text("Your agents and logins stay on your own computer. Pair it once by scanning the code it shows.")
                .font(.footnote)
                .foregroundStyle(TaviTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                showingPairing = true
            } label: {
                Label("Scan pairing code", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.taviProminent)
            .padding(.top, 6)
            .accessibilityIdentifier("sessions.scanPairingCode")
            Label("No provider login. No public relay.", systemImage: "lock")
                .font(.caption2)
                .foregroundStyle(TaviTheme.textSecondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 16)
        .taviCard()
    }

    private func lastKnownBanner(_ computer: HomeComputer) -> some View {
        HStack(spacing: 8) {
            if computer.health == .stale {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "moon.zzz")
                    .font(.caption)
            }
            Text(
                computer.health == .stale
                    ? "Reconnecting — showing the last known state"
                    : "\(computer.name) isn't answering — showing the last known state"
            )
            .font(.caption)
            .foregroundStyle(TaviTheme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .taviCard()
        .accessibilityIdentifier("sessions.stale")
    }

    private func loadingCard(_ computer: HomeComputer) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Connecting to \(computer.name)…")
                .font(.callout)
                .foregroundStyle(TaviTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .taviCard()
        .accessibilityIdentifier("sessions.loading")
    }

    // The computer does not answer at all and nothing was ever shown for
    // it. Once something has loaded, the last known state stays on screen
    // under the "Offline" header instead (PRD §7.8).
    private func offlineCard(_ computer: HomeComputer) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "moon.zzz")
                .foregroundStyle(TaviTheme.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(computer.name) isn't answering. It may be asleep or not on your Tailscale network.")
                    .font(.callout)
                    .foregroundStyle(TaviTheme.textPrimary)
                Text("Tavi keeps trying on its own.")
                    .font(.caption)
                    .foregroundStyle(TaviTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .taviCard()
        .accessibilityIdentifier("sessions.offline")
    }

    private func unavailableCard(_ computer: HomeComputer) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(TaviTheme.statusBlocked)
            VStack(alignment: .leading, spacing: 6) {
                Text(computer.reason ?? "Waiting for \(computer.name).")
                    .font(.callout)
                    .foregroundStyle(TaviTheme.textPrimary)
                Text("Tavi keeps retrying on its own.")
                    .font(.caption)
                    .foregroundStyle(TaviTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .taviCard(stripe: TaviTheme.statusBlocked)
        .accessibilityIdentifier("sessions.agentsUnavailable")
    }

    // The credential is dead on the host side (#46); nothing on this phone
    // can revive it, so the offers are pairing again or letting it go. The
    // other computers are untouched either way (#50). Pair again keeps the
    // record until the new pairing lands — cancelling the scan must not
    // silently lose the computer — and the same fingerprint replaces it.
    private func revokedCard(_ computer: HomeComputer) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .foregroundStyle(TaviTheme.statusBlocked)
            VStack(alignment: .leading, spacing: 8) {
                Text(computer.reason ?? "This iPhone is no longer paired with \(computer.name).")
                    .font(.callout)
                    .foregroundStyle(TaviTheme.textPrimary)
                HStack(spacing: 10) {
                    Button("Pair again") {
                        showingPairing = true
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("sessions.pairAgain")
                    Button("Remove") {
                        removingHostId = computer.id
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(TaviTheme.textSecondary)
                    .accessibilityIdentifier("sessions.removeHost")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .taviCard(stripe: TaviTheme.statusBlocked)
        .accessibilityIdentifier("sessions.revoked")
    }

    private func idleCard(_ computers: [HomeComputer]) -> some View {
        Text(
            computers.count == 1
                ? "No agents are running on \(computers[0].name) right now."
                : "No agents are running on your computers right now."
        )
            .font(.callout)
            .foregroundStyle(TaviTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .taviCard()
            .accessibilityIdentifier("sessions.idle")
    }

    // MARK: - Actions

    private var hostForm: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("https://your-mac.tailnet.ts.net", text: $draftHost)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section {
                    SecureField("Access token", text: $draftToken)
                } header: {
                    Text("Access token")
                } footer: {
                    Text("Stored in this iPhone's Keychain, on this device only. Tavi never uploads it. Anyone with this token can run commands on that computer.")
                }
            }
            .navigationTitle("Connect Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingHostForm = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let address = draftHost.trimmingCharacters(in: .whitespacesAndNewlines)
                        let token = draftToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !address.isEmpty, !token.isEmpty {
                            fleet.add(.typed(address: address), credential: token)
                        }
                        showingHostForm = false
                    }
                }
            }
        }
    }

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

#Preview {
    SessionsView()
}
