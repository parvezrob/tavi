import SwiftUI

// Sessions home (ROADMAP Phase C): what needs the user leads, running work
// follows, finished work drops to a quiet recent list. The mockups in
// docs/assets are reference; the binding contract is PRD §7.1 and the
// navigation map. The home reads computer → project → agents (#26), and
// every terminal is one herdr agent pane (#53).
struct SessionsView: View {
    @Environment(\.scenePhase) private var scenePhase
    // Development connection storage; Phase D replaces this with QR pairing
    // and per-device Keychain credentials.
    @AppStorage("mocha.dev.host") private var storedHost = ""
    // The token lives in the Keychain (#31); this mirrors it for the view.
    // Write through persistToken so state and Keychain never disagree.
    @State private var storedToken = ""
    @State private var agentDirectory = AgentDirectory()
    @State private var draftHost = ""
    @State private var draftToken = ""
    @State private var showingHostForm = false
    @State private var showingPairing = false
    @State private var showingSettings = false
    // "Pair a different Mac" from inside Settings must wait for the
    // Settings sheet to finish dismissing before the pairing sheet can
    // present; flipping both flags in one turn silently drops the second.
    @State private var pairingAfterSettings = false
    @State private var showingNewAgent = false
    @State private var decisionAgent: AgentSummary?
    @State private var terminalController = TerminalSessionController()
    @State private var terminalIsPresented = false
    // What the home calls the paired computer (#26). Held in state rather
    // than read from defaults on every body pass: the home re-renders on
    // every status event and every freshness tick.
    @State private var computerName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                // Deliberately not lazy: the home holds a handful of rows,
                // and LazyVStack's subview caching served a stale card (old
                // status pill) after a row moved between sections.
                VStack(alignment: .leading, spacing: 12) {
                    homeContent
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 28)
            }
            .background(MochaTheme.canvas.ignoresSafeArea())
            .navigationTitle("Mocha")
            .accessibilityIdentifier("sessions.list")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New agent", systemImage: "plus") {
                        showingNewAgent = true
                    }
                    .disabled(!agentDirectory.isConfigured)
                    .accessibilityIdentifier("sessions.newAgentTab")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Pairing is the way in (#45). The typed host/token form
                    // survives only in DEBUG for simulator and UI-test runs.
                    Menu {
                        // "This iPhone" lives under Settings → Security (#51).
                        Button("Settings", systemImage: "gearshape") { showingSettings = true }
                            .accessibilityIdentifier("sessions.settings")
                        Button("Pair a Mac", systemImage: "qrcode.viewfinder") { showingPairing = true }
                            .accessibilityIdentifier("sessions.pair")
                        #if DEBUG
                        Button("Enter host and token (dev)", systemImage: "keyboard") {
                            draftHost = storedHost
                            draftToken = storedToken
                            showingHostForm = true
                        }
                        .accessibilityIdentifier("sessions.hostSettings")
                        #endif
                    } label: {
                        Label("Host", systemImage: "desktopcomputer")
                    }
                    .accessibilityIdentifier("sessions.hostMenu")
                }
            }
            .navigationDestination(isPresented: $terminalIsPresented) {
                TerminalSessionView(
                    controller: terminalController,
                    agentDirectory: agentDirectory,
                    onSelectAgent: { agent in openAgent(agent) }
                )
            }
            .sheet(isPresented: $showingNewAgent) {
                NewAgentSheet(directory: agentDirectory)
            }
            .sheet(isPresented: $showingPairing) {
                PairingFlowView { endpoint, grant in
                    storedHost = endpoint.baseURL.absoluteString
                    persistToken(grant.credential)
                    PairedHostRecord(
                        hostName: grant.hostName,
                        fingerprint: grant.fingerprint,
                        deviceId: grant.deviceId,
                        deviceName: grant.deviceName,
                        pairedAt: Date()
                    ).save()
                    refreshComputerName()
                    agentDirectory.configure(hostText: storedHost, credential: storedToken)
                }
            }
            .sheet(isPresented: $showingSettings, onDismiss: {
                if pairingAfterSettings {
                    pairingAfterSettings = false
                    showingPairing = true
                }
            }) {
                SettingsView(
                    hostAddress: storedHost,
                    directory: agentDirectory,
                    onForget: { forgetHost() },
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
            .sheet(item: $decisionAgent) { agent in
                PermissionDecisionSheet(
                    agent: agent,
                    directory: agentDirectory,
                    onOpenTerminal: { openAgent(agent) }
                )
                .presentationDetents([.medium, .large])
            }
            .task {
                HostCredentialStore.migrateFromDefaults()
                storedToken = HostCredentialStore.load()
                #if DEBUG
                // UI tests must not inherit a connection persisted by an
                // earlier run on the same simulator.
                if ProcessInfo.processInfo.environment["MOCHA_DEV_RESET"] == "1" {
                    storedHost = ""
                    persistToken("")
                    PairedHostRecord.clear()
                    TerminalFontPreference.reset()
                    TerminalViewportRecord.clear()
                    UserDefaults.standard.removeObject(forKey: AppLock.storageKey)
                }
                #endif
                seedFromDevelopmentEnvironmentIfNeeded()
                #if DEBUG
                // Scripted font-size runs (#51): the terminal preference is
                // in the app container, unreachable from simctl, so live
                // verification seeds it here like the other MOCHA_DEV_ keys.
                if let raw = ProcessInfo.processInfo.environment["MOCHA_DEV_FONT_SIZE"],
                   let size = Double(raw) {
                    TerminalFontPreference.save(size)
                }
                #endif
                refreshComputerName()
                agentDirectory.configure(hostText: storedHost, credential: storedToken)
                #if DEBUG
                // Scripted development runs and the terminal UI tests jump
                // straight into one agent's terminal without a tap. The
                // pane is attached by id because the agent list may not
                // have loaded yet; a pane that does not exist fails
                // honestly on the terminal itself.
                if let paneID = TerminalDevelopmentBootstrap.launchEnvironment().agentPaneID {
                    openAgent(paneID: paneID)
                }
                #endif
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    terminalController.sceneDidBecomeActive()
                    agentDirectory.start()
                case .background:
                    terminalController.sceneWillResignActive()
                    agentDirectory.stop()
                case .inactive:
                    break
                @unknown default:
                    terminalController.sceneWillResignActive()
                    agentDirectory.stop()
                }
            }
        }
    }

    // MARK: - Home sections

    @ViewBuilder
    private var homeContent: some View {
        if !agentDirectory.isConfigured {
            // The first impression owns the middle of the screen, not the
            // top edge of an otherwise empty page (#54).
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                noHostCard
                Spacer(minLength: 0)
            }
            .containerRelativeFrame(.vertical) { length, _ in length * 0.7 }
        } else if !agentDirectory.hasLoaded {
            loadingCard
        } else if !agentDirectory.available {
            degradedCard
        } else {
            if agentDirectory.isStale {
                staleBanner
            }
            let layout = homeLayout

            if !layout.needsYou.isEmpty {
                // With a single waiting agent the striped card below says
                // everything the banner would; the banner earns its row only
                // as a tally of several (#54).
                // One header, never two: the banner is the section header
                // when several wait; the eyebrow is when one does.
                if layout.needsYou.count > 1 {
                    NeedsYouBanner(count: layout.needsYou.count) {
                        if let first = layout.needsYou.first { decisionAgent = first }
                    }
                } else {
                    SectionEyebrow(title: "Needs you")
                }
                // Needs-you is flat and first, across every computer and
                // project: a waiting agent never hides under a group.
                // Identity includes the status so a section move always
                // rebuilds the card instead of reusing a cached one. A
                // needs-you card opens the decision sheet (approve/deny
                // without the terminal); everything else opens the terminal.
                ForEach(layout.needsYou, id: \.cardIdentity) { agent in
                    agentCard(agent, showsLocation: true, action: { decisionAgent = agent })
                }
            }

            // Computer → project → agents (#26). Running work sits as full
            // cards under its folder; finished and idle work shares one
            // compact card below them. A blocked agent is only in the flat
            // list above — its project header counts it, never repeats it.
            ForEach(layout.computers) { computer in
                ComputerHeader(computer: computer)
                ForEach(computer.projects) { project in
                    ProjectHeader(project: project)
                    ForEach(project.active, id: \.cardIdentity) { agent in
                        agentCard(agent, showsLocation: false, action: { openAgent(agent) })
                    }
                    if !project.recent.isEmpty {
                        recentCard(project.recent)
                    }
                }
            }

            if layout.isEmpty {
                idleStateCard
            }
        }
    }

    private var homeLayout: HomeLayout {
        HomeGrouping.layout(agents: agentDirectory.agents, computer: (id: storedHost, name: computerName))
    }

    private func refreshComputerName() {
        computerName = HomeGrouping.computerName(pairedName: PairedHostRecord.load()?.hostName, hostText: storedHost)
    }

    private func agentCard(_ agent: AgentSummary, showsLocation: Bool, action: @escaping () -> Void) -> some View {
        AgentCard(
            agent: agent,
            preview: agentDirectory.previews[agent.id],
            observedAt: agentDirectory.statusObservedAt[agent.id],
            showsLocation: showsLocation,
            action: action
        )
    }

    private func recentCard(_ agents: [AgentSummary]) -> some View {
        VStack(spacing: 0) {
            ForEach(agents, id: \.cardIdentity) { agent in
                RecentAgentRow(
                    agent: agent,
                    observedAt: agentDirectory.statusObservedAt[agent.id]
                ) {
                    openAgent(agent)
                }
                if agent.id != agents.last?.id {
                    Divider().overlay(MochaTheme.hairline)
                }
            }
        }
        .mochaCard()
    }

    // MARK: - Empty and degraded states

    // First run leads with the promise, not the absence (#54): what Mocha
    // is for, then the one step, then the trust line that used to hide in
    // the pairing sheet's footer.
    private var noHostCard: some View {
        VStack(spacing: 10) {
            Text("Your Mac's agents, in your pocket")
                .font(.title3.weight(.semibold))
                .foregroundStyle(MochaTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text("Your agents and logins stay on your Mac. Pair it once by scanning the code it shows.")
                .font(.footnote)
                .foregroundStyle(MochaTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                showingPairing = true
            } label: {
                Label("Scan pairing code", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.mochaProminent)
            .padding(.top, 6)
            .accessibilityIdentifier("sessions.scanPairingCode")
            Label("No provider login. No public relay.", systemImage: "lock")
                .font(.caption2)
                .foregroundStyle(MochaTheme.textSecondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 16)
        .mochaCard()
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Connecting to the host…")
                .font(.callout)
                .foregroundStyle(MochaTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .mochaCard()
        .accessibilityIdentifier("sessions.loading")
    }

    // The stream is down: everything below is the last known state and says
    // so, instead of vanishing (PRD §7.8). A waiting agent stays visible.
    private var staleBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
            Text("Reconnecting — showing the last known state")
                .font(.caption)
                .foregroundStyle(MochaTheme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .mochaCard()
        .accessibilityIdentifier("sessions.stale")
    }

    private var degradedCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: agentDirectory.isRevoked ? "person.crop.circle.badge.xmark" : "exclamationmark.triangle")
                .foregroundStyle(MochaTheme.statusBlocked)
            VStack(alignment: .leading, spacing: 6) {
                Text(agentDirectory.reason ?? "Waiting for the host.")
                    .font(.callout)
                    .foregroundStyle(MochaTheme.textPrimary)
                if agentDirectory.isRevoked {
                    // The credential is dead on the host side (#46); nothing
                    // on this phone can revive it, so the only offer is pairing.
                    Button("Pair again") {
                        persistToken("")
                        PairedHostRecord.clear()
                        showingPairing = true
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("sessions.pairAgain")
                } else {
                    Text("Mocha keeps retrying on its own.")
                        .font(.caption)
                        .foregroundStyle(MochaTheme.textSecondary)
                }
            }
        }
        .padding(14)
        .mochaCard(stripe: MochaTheme.statusBlocked)
        .accessibilityIdentifier(agentDirectory.isRevoked ? "sessions.revoked" : "sessions.agentsUnavailable")
    }

    private var idleStateCard: some View {
        Text("No agents are running in Herdr right now.")
            .font(.callout)
            .foregroundStyle(MochaTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .mochaCard()
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
                    Text("Stored in this iPhone's Keychain, on this device only. Mocha never uploads it. Anyone with this token can run commands on your Mac.")
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
                        storedHost = draftHost.trimmingCharacters(in: .whitespacesAndNewlines)
                        persistToken(draftToken.trimmingCharacters(in: .whitespacesAndNewlines))
                        refreshComputerName()
                        agentDirectory.configure(hostText: storedHost, credential: storedToken)
                        showingHostForm = false
                    }
                }
            }
        }
    }

    private func openAgent(_ agent: AgentSummary) {
        openAgent(paneID: agent.id)
    }

    private func openAgent(paneID: String) {
        terminalController.stop()
        terminalController.connect(hostText: storedHost, paneID: paneID, credential: storedToken)
        terminalIsPresented = true
    }

    private func seedFromDevelopmentEnvironmentIfNeeded() {
        // Release builds must never persist an injected credential (#33).
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if storedHost.isEmpty, let host = environment["MOCHA_DEV_HOST"] {
            storedHost = host
        }
        if storedToken.isEmpty, let token = environment["MOCHA_DEV_TOKEN"] {
            persistToken(token)
        }
        #endif
    }

    // Back to "No Paired Computers": credential gone from the Keychain,
    // address and pairing record gone from defaults, directory reset.
    private func forgetHost() {
        persistToken("")
        storedHost = ""
        PairedHostRecord.clear()
        refreshComputerName()
        agentDirectory.configure(hostText: "", credential: "")
    }

    private func persistToken(_ token: String) {
        storedToken = token
        HostCredentialStore.save(token)
    }
}

#Preview {
    SessionsView()
}
