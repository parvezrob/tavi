import SwiftUI
import UIKit

struct TerminalSessionView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var credential = ""
    @State private var host = ""
    @State private var sessionID = ""
    @State private var showingConnection = true
    @State private var showingJump = false
    @State private var didApplyDevelopmentBootstrap = false

    let controller: TerminalSessionController
    // Present only when the terminal was opened from the agent home; drives
    // the identity header and the Jump-to sheet. tmux and development
    // terminals keep the generic chrome.
    private let agentDirectory: AgentDirectory?
    private let onSelectAgent: ((AgentSummary) -> Void)?
    private let developmentBootstrap: TerminalDevelopmentBootstrap

    init(
        controller: TerminalSessionController,
        agentDirectory: AgentDirectory? = nil,
        onSelectAgent: ((AgentSummary) -> Void)? = nil,
        developmentBootstrap: TerminalDevelopmentBootstrap = .launchEnvironment()
    ) {
        let bootstrap = developmentBootstrap
        self.developmentBootstrap = bootstrap
        self.controller = controller
        self.agentDirectory = agentDirectory
        self.onSelectAgent = onSelectAgent
        _host = State(initialValue: bootstrap.host)
        _sessionID = State(initialValue: bootstrap.sessionID)
        _credential = State(initialValue: bootstrap.credential)
        _showingConnection = State(
            initialValue: controller.needsConnectionConfiguration
                && !bootstrap.isComplete
                && bootstrap.rendererStressChunks == nil
        )
    }

    // The connected agent's live identity from the events mirror; nil for
    // tmux targets or when the directory is not available.
    private var activeAgent: AgentSummary? {
        guard controller.currentTargetKind == .herdrAgent,
              let paneID = controller.currentSessionID else { return nil }
        return agentDirectory?.agents.first { $0.id == paneID }
    }

    private var canJump: Bool {
        agentDirectory != nil
            && onSelectAgent != nil
            && controller.currentTargetKind == .herdrAgent
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionBanner
            AgentTerminalView(
                bridge: controller.bridge,
                isActive: scenePhase == .active,
                onGridSizeChange: controller.terminalGridDidChange,
                onRendererReady: controller.terminalRendererDidAttach,
                onRendererFailure: controller.rendererDidFail
            )
            .background(.black)
            .overlay {
                if controller.needsConnectionConfiguration,
                   developmentBootstrap.rendererStressChunks == nil {
                    disconnectedPrompt
                }
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .navigationTitle(activeAgent == nil ? "Terminal" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let agent = activeAgent {
                ToolbarItem(placement: .principal) {
                    identityHeader(agent)
                }
            }
            if canJump {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Jump", systemImage: "arrow.triangle.branch") {
                        showingJump = true
                    }
                    .accessibilityIdentifier("terminal.jump")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Connection", systemImage: "network") {
                    showingConnection = true
                }
                .accessibilityIdentifier("terminal.connection")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            terminalControls
        }
        .sheet(isPresented: $showingConnection) {
            connectionSheet
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingJump) {
            if let agentDirectory, let onSelectAgent {
                JumpToSheet(
                    agentDirectory: agentDirectory,
                    currentPaneID: controller.currentSessionID,
                    onSelect: onSelectAgent
                )
                .presentationDetents([.medium, .large])
            }
        }
        .task {
            #if DEBUG
            if let chunks = developmentBootstrap.rendererStressChunks {
                while !Task.isCancelled {
                    for chunk in chunks {
                        guard !Task.isCancelled else { return }
                        controller.renderDevelopmentOutput(chunk)
                        await Task.yield()
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return
            }
            #endif
            guard developmentBootstrap.isComplete,
                  controller.needsConnectionConfiguration,
                  !didApplyDevelopmentBootstrap else { return }
            didApplyDevelopmentBootstrap = true
            controller.connect(
                hostText: developmentBootstrap.host,
                sessionText: developmentBootstrap.sessionID,
                credential: developmentBootstrap.credential
            )
            credential = ""
        }
    }

    private func identityHeader(_ agent: AgentSummary) -> some View {
        let status = AgentStatusStyle.of(agent.status)
        return VStack(spacing: 1) {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.color)
                    .frame(width: 7, height: 7)
                Text(agent.displayName)
                    .font(.subheadline.weight(.semibold))
            }
            Text(agent.projectName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.displayName), \(agent.projectName), \(status.label)")
        .accessibilityIdentifier("terminal.identity")
    }

    private var connectionBanner: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 8, height: 8)
                Text(controller.connectionState.accessibilityDescription)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
            }
            if let error = controller.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("terminal.status")
    }

    private var terminalControls: some View {
        HStack(spacing: 8) {
            Button("Keyboard", systemImage: "keyboard") {
                controller.bridge.focusTerminal()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!controller.connectionState.canSubmitInput)
            .accessibilityIdentifier("terminal.keyboard")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TerminalQuickKey.allCases) { key in
                        Button(key.rawValue) {
                            controller.sendQuickKey(key)
                            controller.bridge.focusTerminal()
                        }
                        .buttonStyle(.bordered)
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(!controller.connectionState.canSubmitInput)
                        .accessibilityLabel(quickKeyAccessibilityLabel(key))
                    }

                    Button("Paste", systemImage: "doc.on.clipboard") {
                        if let pasted = UIPasteboard.general.string {
                            controller.paste(pasted)
                            controller.bridge.focusTerminal()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!controller.connectionState.canSubmitInput)
                    .accessibilityIdentifier("terminal.paste")
                    .accessibilityHint("Reads the clipboard only after you tap")
                }
            }

            Button("Hide keyboard", systemImage: "keyboard.chevron.compact.down") {
                controller.bridge.dismissKeyboard()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("terminal.dismissKeyboard")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var disconnectedPrompt: some View {
        ContentUnavailableView {
            Label("Connect a terminal", systemImage: "terminal")
        } description: {
            Text("Attach to a tmux session on your computer to start typing.")
        } actions: {
            Button("Open Connection") {
                showingConnection = true
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding()
        .accessibilityIdentifier("terminal.disconnected")
    }

    private var connectionSheet: some View {
        NavigationStack {
            Form {
                Section("Development host") {
                    TextField("https://mac-name.tailnet.ts.net", text: $host)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("connection.host")
                    TextField("tmux session ID", text: $sessionID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("connection.session")
                    SecureField("Host access token", text: $credential)
                        .textContentType(.password)
                        .accessibilityIdentifier("connection.token")
                }

                Section {
                    Button("Connect") {
                        controller.connect(
                            hostText: host,
                            sessionText: sessionID,
                            credential: credential
                        )
                        credential = ""
                        showingConnection = false
                    }
                    .disabled(host.isEmpty || sessionID.isEmpty || credential.isEmpty)
                    .accessibilityIdentifier("connection.connect")

                    if controller.connectionState != .idle {
                        Button("Disconnect", role: .destructive) {
                            controller.stop()
                            showingConnection = true
                        }
                    }
                } footer: {
                    Text("The token stays in memory for this connection and is never saved or logged. Only Tailscale Serve .ts.net addresses are accepted. Mocha cannot detect Funnel, so keep Funnel disabled.")
                }
            }
            .accessibilityIdentifier("connection.sheet")
            .navigationTitle("Connection")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingConnection = false }
                }
            }
        }
    }

    private var connectionColor: Color {
        switch controller.connectionState {
        case .connected:
            .green
        case .connecting, .reconnecting, .waitingForNetwork:
            .orange
        case .failed, .ended:
            .red
        case .idle, .suspended:
            .secondary
        }
    }

    private func quickKeyAccessibilityLabel(_ key: TerminalQuickKey) -> String {
        switch key {
        case .escape: "Escape"
        case .tab: "Tab"
        case .interrupt: "Interrupt with Control C"
        case .left: "Left arrow"
        case .up: "Up arrow"
        case .down: "Down arrow"
        case .right: "Right arrow"
        }
    }
}

#Preview {
    NavigationStack {
        TerminalSessionView(controller: TerminalSessionController())
    }
}
