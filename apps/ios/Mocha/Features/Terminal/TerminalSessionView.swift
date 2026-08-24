import SwiftUI
import UIKit

// Exactly one typing target exists at any moment: the composer drafts a
// deliberate message locally, live mode sends every keystroke straight to
// the pty. The Keyboard key (or tapping the terminal) switches modes.
private enum TerminalInputMode {
    case compose
    case live
}

struct TerminalSessionView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var credential = ""
    @State private var host = ""
    @State private var sessionID = ""
    @State private var showingConnection = true
    @State private var showingJump = false
    @State private var didApplyDevelopmentBootstrap = false
    @State private var composerText = ""
    @State private var composerError: String?
    @State private var composerSending = false
    @State private var inputMode: TerminalInputMode = .compose
    @FocusState private var composerFocused: Bool

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
            // Tapping the terminal is an implicit switch to live typing, so
            // the composer never lingers as a second empty text target.
            .simultaneousGesture(
                TapGesture().onEnded {
                    if inputMode == .compose, controller.connectionState.canSubmitInput {
                        withAnimation(.easeInOut(duration: 0.2)) { inputMode = .live }
                    }
                }
            )
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
            HStack(spacing: 7) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 7, height: 7)
                Text(controller.connectionState.accessibilityDescription)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MochaTheme.textSecondary)
                Spacer(minLength: 8)
            }
            if let error = controller.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(MochaTheme.statusBlocked)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(MochaTheme.card)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MochaTheme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("terminal.status")
    }

    // Opaque charcoal input bar in the terminal's own visual world: a key
    // row styled as key caps, then a single input surface — the composer
    // or the live-typing hint, never both.
    private var terminalControls: some View {
        VStack(spacing: 10) {
            quickKeyRow
            if inputMode == .compose {
                composerBar
                    .transition(.opacity)
            } else {
                liveTypingRow
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(MochaTheme.card)
        .overlay(alignment: .top) {
            Rectangle().fill(MochaTheme.hairline).frame(height: 1)
        }
    }

    private var liveTypingRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(MochaTheme.statusDone)
                .frame(width: 6, height: 6)
            Text("Live typing — keys go straight to the terminal")
                .font(.caption)
                .foregroundStyle(MochaTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Compose") {
                switchToCompose()
            }
            .buttonStyle(TerminalKeyStyle())
            .accessibilityIdentifier("terminal.composeMode")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.liveHint")
    }

    private func switchToLive() {
        withAnimation(.easeInOut(duration: 0.2)) { inputMode = .live }
        composerFocused = false
        controller.bridge.focusTerminal()
    }

    private func switchToCompose() {
        controller.bridge.dismissKeyboard()
        withAnimation(.easeInOut(duration: 0.2)) { inputMode = .compose }
        composerFocused = true
    }

    // Deliberate send is the PRD's primary input mode: text stays local
    // until the send button, and nothing is ever replayed automatically.
    private var composerBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    activeAgent == nil ? "Type a command…" : "Message \(activeAgent?.displayName ?? "the agent")…",
                    text: $composerText,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .font(.system(.callout, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($composerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    MochaTheme.well,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .accessibilityIdentifier("terminal.composer")

                Button {
                    sendComposer()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(
                    composerSending
                        || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !controller.connectionState.canSubmitInput
                )
                .accessibilityLabel("Send")
                .accessibilityIdentifier("terminal.composerSend")
            }
            if let composerError {
                Text(composerError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var quickKeyRow: some View {
        HStack(spacing: 8) {
            Button {
                if inputMode == .live {
                    switchToCompose()
                } else {
                    switchToLive()
                }
            } label: {
                Image(systemName: "keyboard")
            }
            .buttonStyle(TerminalKeyStyle(armed: inputMode == .live))
            .disabled(!controller.connectionState.canSubmitInput)
            .accessibilityLabel(
                inputMode == .live ? "Live typing on, switch to composer" : "Live typing"
            )
            .accessibilityIdentifier("terminal.keyboard")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button("ctrl") {
                        controller.toggleControlLatch()
                        refocusAfterKey()
                    }
                    .buttonStyle(TerminalKeyStyle(armed: controller.controlLatchActive))
                    .disabled(!controller.connectionState.canSubmitInput)
                    .accessibilityLabel(
                        controller.controlLatchActive
                            ? "Control modifier armed, next key sends its control code"
                            : "Control modifier"
                    )
                    .accessibilityIdentifier("terminal.ctrl")

                    ForEach(TerminalQuickKey.allCases) { key in
                        Button {
                            controller.sendQuickKey(key)
                            refocusAfterKey()
                        } label: {
                            keyCapLabel(key)
                        }
                        .buttonStyle(TerminalKeyStyle())
                        .disabled(!controller.connectionState.canSubmitInput)
                        .accessibilityLabel(quickKeyAccessibilityLabel(key))
                    }

                    Button {
                        if let pasted = UIPasteboard.general.string {
                            controller.paste(pasted)
                            refocusAfterKey()
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .buttonStyle(TerminalKeyStyle())
                    .disabled(!controller.connectionState.canSubmitInput)
                    .accessibilityLabel("Paste")
                    .accessibilityIdentifier("terminal.paste")
                    .accessibilityHint("Reads the clipboard only after you tap")
                }
            }

            Button {
                controller.bridge.dismissKeyboard()
                composerFocused = false
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
            }
            .buttonStyle(TerminalKeyStyle())
            .accessibilityLabel("Hide keyboard")
            .accessibilityIdentifier("terminal.dismissKeyboard")
        }
    }

    // Quick keys never steal the typing target: they refocus the terminal
    // only while live typing is the active mode.
    private func refocusAfterKey() {
        if inputMode == .live {
            controller.bridge.focusTerminal()
        }
    }

    // Key-cap faces: lowercase words like a hardware keyboard, crisp SF
    // arrows instead of text glyphs.
    @ViewBuilder
    private func keyCapLabel(_ key: TerminalQuickKey) -> some View {
        switch key {
        case .escape: Text("esc")
        case .tab: Text("tab")
        case .shiftTab: Text("⇧tab")
        case .enter: Image(systemName: "return")
        case .interrupt: Text("^C")
        case .left: Image(systemName: "arrow.left")
        case .up: Image(systemName: "arrow.up")
        case .down: Image(systemName: "arrow.down")
        case .right: Image(systemName: "arrow.right")
        }
    }

    // Herdr agents receive the composer through the structured prompt
    // endpoint; plain terminals get bracketed-paste text plus one explicit
    // return. Text clears only after a confirmed hand-off.
    private func sendComposer() {
        let text = composerText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        composerError = nil
        if let agent = activeAgent, let agentDirectory {
            composerSending = true
            Task {
                let failure = await agentDirectory.promptAgent(paneId: agent.id, text: text)
                composerSending = false
                composerError = failure
                if failure == nil {
                    composerText = ""
                }
            }
        } else {
            controller.sendComposedText(text)
            composerText = ""
        }
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
        case .shiftTab: "Shift Tab"
        case .enter: "Enter"
        case .interrupt: "Interrupt with Control C"
        case .left: "Left arrow"
        case .up: "Up arrow"
        case .down: "Down arrow"
        case .right: "Right arrow"
        }
    }
}

// Key-cap treatment for the terminal control bar: quiet charcoal caps
// with hairline strokes, a soft press state, and an unmistakable amber
// "armed" face for the Ctrl latch.
private struct TerminalKeyStyle: ButtonStyle {
    var armed = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(faceColor)
            .frame(minWidth: 36, minHeight: 38)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(fillColor(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        armed ? Color.clear : Color.white.opacity(isEnabled ? 0.09 : 0.05),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: armed)
    }

    private var faceColor: Color {
        if armed { return Color.black.opacity(0.85) }
        return isEnabled ? MochaTheme.textPrimary : MochaTheme.textPrimary.opacity(0.3)
    }

    private func fillColor(pressed: Bool) -> Color {
        if armed { return MochaTheme.statusBlocked }
        if pressed { return Color.white.opacity(0.18) }
        return Color.white.opacity(isEnabled ? 0.07 : 0.03)
    }
}

#Preview {
    NavigationStack {
        TerminalSessionView(controller: TerminalSessionController())
    }
}
