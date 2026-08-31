import SwiftUI

// Sessions home (ROADMAP Phase C): what needs the user leads, running work
// follows, finished work drops to a quiet recent list. The mockups in
// docs/assets are reference; the binding contract is PRD §7.1 and the
// navigation map. Terminal access always stays reachable, even with no
// host or Herdr down.
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
    @State private var showingNewAgent = false
    @State private var decisionAgent: AgentSummary?
    @State private var terminalController = TerminalSessionController()
    @State private var terminalIsPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                // Deliberately not lazy: the home holds a handful of rows,
                // and LazyVStack's subview caching served a stale card (old
                // status pill) after a row moved between sections.
                VStack(alignment: .leading, spacing: 12) {
                    homeContent
                    terminalFallbackCard
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
                PairingFlowView { endpoint, credential in
                    storedHost = endpoint.baseURL.absoluteString
                    persistToken(credential)
                    agentDirectory.configure(hostText: storedHost, credential: storedToken)
                }
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
                }
                #endif
                seedFromDevelopmentEnvironmentIfNeeded()
                agentDirectory.configure(hostText: storedHost, credential: storedToken)
                #if DEBUG
                // Scripted development runs (simulator automation) jump
                // straight to the terminal without a tap.
                if ProcessInfo.processInfo.environment["MOCHA_DEV_AUTO_OPEN_TERMINAL"] == "1" {
                    terminalIsPresented = true
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
            noHostCard
        } else if !agentDirectory.hasLoaded {
            loadingCard
        } else if !agentDirectory.available {
            degradedCard
        } else {
            if agentDirectory.isStale {
                staleBanner
            }
            let blocked = agents(in: .needsYou)
            let active = agents(in: .active)
            let recent = agents(in: .recent)

            if !blocked.isEmpty {
                NeedsYouBanner(count: blocked.count) {
                    if let first = blocked.first { decisionAgent = first }
                }
                SectionEyebrow(title: "Needs you")
                // Identity includes the status so a section move always
                // rebuilds the card instead of reusing a cached one. A
                // needs-you card opens the decision sheet (approve/deny
                // without the terminal); other sections open the terminal.
                ForEach(blocked, id: \.cardIdentity) { agent in
                    agentCard(agent, action: { decisionAgent = agent })
                }
            }

            if !active.isEmpty {
                SectionEyebrow(title: "Active")
                ForEach(active, id: \.cardIdentity) { agent in
                    agentCard(agent, action: { openAgent(agent) })
                }
            }

            if !recent.isEmpty {
                SectionEyebrow(title: "Recent")
                recentCard(recent)
            }

            if blocked.isEmpty, active.isEmpty, recent.isEmpty {
                idleStateCard
            }
        }
    }

    private func agents(in section: AgentHomeSection) -> [AgentSummary] {
        agentDirectory.agents.filter { $0.homeSection == section }
    }

    private func agentCard(_ agent: AgentSummary, action: @escaping () -> Void) -> some View {
        AgentCard(
            agent: agent,
            preview: agentDirectory.previews[agent.id],
            observedAt: agentDirectory.statusObservedAt[agent.id],
            action: action
        )
    }

    private func recentCard(_ agents: [AgentSummary]) -> some View {
        VStack(spacing: 0) {
            ForEach(agents) { agent in
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

    private var noHostCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(MochaTheme.textSecondary)
            Text("No Paired Computers")
                .font(.headline)
                .foregroundStyle(MochaTheme.textPrimary)
            Text("Your agents and logins stay on your Mac. Pair it once by scanning the code it shows.")
                .font(.footnote)
                .foregroundStyle(MochaTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                showingPairing = true
            } label: {
                Label("Scan pairing code", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
            .accessibilityIdentifier("sessions.scanPairingCode")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
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
                        showingPairing = true
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("sessions.pairAgain")
                } else {
                    Text("The terminal below still works.")
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

    private var terminalFallbackCard: some View {
        Button {
            terminalIsPresented = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .foregroundStyle(MochaTheme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Terminal")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MochaTheme.textPrimary)
                    Text("Open a tmux session directly")
                        .font(.caption)
                        .foregroundStyle(MochaTheme.textSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MochaTheme.textSecondary)
            }
            .padding(14)
            .contentShape(Rectangle())
            .mochaCard()
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .accessibilityIdentifier("sessions.openTerminal")
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
                        agentDirectory.configure(hostText: storedHost, credential: storedToken)
                        showingHostForm = false
                    }
                }
            }
        }
    }

    private func openAgent(_ agent: AgentSummary) {
        terminalController.stop()
        terminalController.connect(
            hostText: storedHost,
            sessionText: agent.id,
            credential: storedToken,
            target: .herdrAgent
        )
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

    private func persistToken(_ token: String) {
        storedToken = token
        HostCredentialStore.save(token)
    }
}

#Preview {
    SessionsView()
}
