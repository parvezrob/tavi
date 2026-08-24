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
    @AppStorage("mocha.dev.token") private var storedToken = ""
    @State private var agentDirectory = AgentDirectory()
    @State private var draftHost = ""
    @State private var draftToken = ""
    @State private var newTabError: String?
    @State private var newTabInFlight = false
    @State private var showingHostForm = false
    @State private var showingNewTabPicker = false
    @State private var terminalController = TerminalSessionController()
    @State private var terminalIsPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
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
                        showingNewTabPicker = true
                    }
                    .disabled(!agentDirectory.isConfigured || newTabInFlight)
                    .accessibilityIdentifier("sessions.newAgentTab")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Host", systemImage: "desktopcomputer") {
                        draftHost = storedHost
                        draftToken = storedToken
                        showingHostForm = true
                    }
                    .accessibilityIdentifier("sessions.hostSettings")
                }
            }
            .confirmationDialog("New Herdr tab", isPresented: $showingNewTabPicker) {
                Button("Claude") { createTab(agent: "claude") }
                Button("Codex") { createTab(agent: "codex") }
                Button("Cancel", role: .cancel) {}
            }
            .navigationDestination(isPresented: $terminalIsPresented) {
                TerminalSessionView(controller: terminalController)
            }
            .sheet(isPresented: $showingHostForm) {
                hostForm
                    .presentationDetents([.medium])
            }
            .task {
                #if DEBUG
                // UI tests must not inherit a connection persisted by an
                // earlier run on the same simulator.
                if ProcessInfo.processInfo.environment["MOCHA_DEV_RESET"] == "1" {
                    storedHost = ""
                    storedToken = ""
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
        } else if !agentDirectory.available {
            degradedCard
        } else {
            let blocked = agents(in: .needsYou)
            let active = agents(in: .active)
            let recent = agents(in: .recent)

            if !blocked.isEmpty {
                NeedsYouBanner(count: blocked.count) {
                    if let first = blocked.first { openAgent(first) }
                }
                SectionEyebrow(title: "Needs you")
                ForEach(blocked) { agentCard($0) }
            }

            if !active.isEmpty {
                SectionEyebrow(title: "Active")
                ForEach(active) { agentCard($0) }
            }

            if !recent.isEmpty {
                SectionEyebrow(title: "Recent")
                recentCard(recent)
            }

            if blocked.isEmpty, active.isEmpty, recent.isEmpty {
                idleStateCard
            }

            if let newTabError {
                Text(newTabError)
                    .font(.caption)
                    .foregroundStyle(MochaTheme.statusBlocked)
            }
        }
    }

    private func agents(in section: AgentHomeSection) -> [AgentSummary] {
        agentDirectory.agents.filter { $0.homeSection == section }
    }

    private func agentCard(_ agent: AgentSummary) -> some View {
        AgentCard(
            agent: agent,
            preview: agentDirectory.previews[agent.id],
            observedAt: agentDirectory.statusObservedAt[agent.id]
        ) {
            openAgent(agent)
        }
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
            Text("Add your Mac's Tailscale address and token to see live agents.")
                .font(.footnote)
                .foregroundStyle(MochaTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Connect Host") {
                draftHost = storedHost
                draftToken = storedToken
                showingHostForm = true
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .mochaCard()
    }

    private var degradedCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(MochaTheme.statusBlocked)
            VStack(alignment: .leading, spacing: 4) {
                Text(agentDirectory.reason ?? "Waiting for the host.")
                    .font(.callout)
                    .foregroundStyle(MochaTheme.textPrimary)
                Text("The terminal below still works.")
                    .font(.caption)
                    .foregroundStyle(MochaTheme.textSecondary)
            }
        }
        .padding(14)
        .mochaCard(stripe: MochaTheme.statusBlocked)
        .accessibilityIdentifier("sessions.agentsUnavailable")
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

    private func createTab(agent: String?) {
        newTabError = nil
        newTabInFlight = true
        Task {
            let failure = await agentDirectory.createTab(agent: agent)
            newTabInFlight = false
            newTabError = failure
        }
    }

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
                Section("Access token") {
                    SecureField("Paste the token from npm run token", text: $draftToken)
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
                        storedToken = draftToken.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let environment = ProcessInfo.processInfo.environment
        if storedHost.isEmpty, let host = environment["MOCHA_DEV_HOST"] {
            storedHost = host
        }
        if storedToken.isEmpty, let token = environment["MOCHA_DEV_TOKEN"] {
            storedToken = token
        }
    }
}

#Preview {
    SessionsView()
}
