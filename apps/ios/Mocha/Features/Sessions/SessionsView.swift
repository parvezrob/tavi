import SwiftUI

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
            List {
                agentsSection

                Section("Terminal") {
                    Button {
                        terminalIsPresented = true
                    } label: {
                        Label("Open terminal", systemImage: "terminal")
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("sessions.openTerminal")
                }
            }
            .navigationTitle("Mocha")
            .accessibilityIdentifier("sessions.list")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Host", systemImage: "desktopcomputer") {
                        draftHost = storedHost
                        draftToken = storedToken
                        showingHostForm = true
                    }
                    .accessibilityIdentifier("sessions.hostSettings")
                }
            }
            .navigationDestination(isPresented: $terminalIsPresented) {
                TerminalSessionView(controller: terminalController)
            }
            .sheet(isPresented: $showingHostForm) {
                hostForm
                    .presentationDetents([.medium])
            }
            .task {
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

    private var agentsSection: some View {
        Section("Agents") {
            if !agentDirectory.isConfigured {
                ContentUnavailableView {
                    Label("No Host Connected", systemImage: "desktopcomputer")
                } description: {
                    Text("Add your Mac's Tailscale address and token to see live agents.")
                } actions: {
                    Button("Connect Host") {
                        draftHost = storedHost
                        draftToken = storedToken
                        showingHostForm = true
                    }
                }
                .listRowBackground(Color.clear)
            } else if !agentDirectory.available {
                Label {
                    Text(agentDirectory.reason ?? "Waiting for the host.")
                        .font(.callout)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                .accessibilityIdentifier("sessions.agentsUnavailable")
            } else {
                if agentDirectory.agents.isEmpty {
                    Text("No agents are running in Herdr right now.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(agentDirectory.agents) { agent in
                        Button {
                            openAgent(agent)
                        } label: {
                            agentRow(agent)
                        }
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("sessions.agent.\(agent.id)")
                    }
                }

                Button {
                    showingNewTabPicker = true
                } label: {
                    Label(newTabInFlight ? "Creating…" : "New Agent Tab", systemImage: "plus.circle")
                }
                .foregroundStyle(.tint)
                .disabled(newTabInFlight)
                .accessibilityIdentifier("sessions.newAgentTab")
                // Empty tabs are omitted until plain panes are visible on the
                // phone — an invisible tab reads as "nothing happened".
                .confirmationDialog("New Herdr tab", isPresented: $showingNewTabPicker) {
                    Button("Claude") { createTab(agent: "claude") }
                    Button("Codex") { createTab(agent: "codex") }
                    Button("Cancel", role: .cancel) {}
                }

                if let newTabError {
                    Text(newTabError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func createTab(agent: String?) {
        newTabError = nil
        newTabInFlight = true
        Task {
            let failure = await agentDirectory.createTab(agent: agent)
            newTabInFlight = false
            newTabError = failure
        }
    }

    private func agentRow(_ agent: AgentSummary) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor(agent.status))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.agent.capitalized)
                        .font(.body.weight(.semibold))
                    Text(agent.status)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusColor(agent.status))
                }
                Text(agent.title.isEmpty ? agent.cwd : agent.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
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

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "blocked": .orange
        case "working": .blue
        case "done": .green
        case "idle": .secondary
        default: .gray
        }
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
