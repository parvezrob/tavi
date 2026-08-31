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
    @State private var showingJump = false
    @State private var composerText = ""
    @State private var composerError: String?
    @State private var composerSending = false
    @State private var inputMode: TerminalInputMode = .compose
    // The real keyboard signal: the Ghostty surface raises the keyboard
    // from UIKit (a tap on it becomes first responder) entirely outside
    // SwiftUI state, so mode flags alone cannot gate the dismiss control.
    @State private var keyboardUp = false
    // Trailing fade only while keys are actually off-screen; a permanent
    // fade reads as a disabled last key.
    @State private var keyRowHasMore = true
    @FocusState private var composerFocused: Bool

    let controller: TerminalSessionController
    // The events mirror behind the identity header and the Jump-to sheet;
    // nil only in previews, which keep the generic chrome.
    private let agentDirectory: AgentDirectory?
    private let onSelectAgent: ((AgentSummary) -> Void)?
    private let developmentBootstrap: TerminalDevelopmentBootstrap

    init(
        controller: TerminalSessionController,
        agentDirectory: AgentDirectory? = nil,
        onSelectAgent: ((AgentSummary) -> Void)? = nil,
        developmentBootstrap: TerminalDevelopmentBootstrap = .launchEnvironment()
    ) {
        self.developmentBootstrap = developmentBootstrap
        self.controller = controller
        self.agentDirectory = agentDirectory
        self.onSelectAgent = onSelectAgent
    }

    // The connected pane's live identity from the events mirror; nil while
    // the list has not caught up with the pane or after the attach failed.
    private var activeAgent: AgentSummary? {
        guard let paneID = controller.currentPaneID else { return nil }
        return agentDirectory?.agents.first { $0.id == paneID }
    }

    // The agent the composer should *prompt*. A shell pane is a herdr agent
    // for listing and attaching, but its input is commands (#43), so it is
    // deliberately nil here and takes the plain-terminal send path.
    private var promptTarget: AgentSummary? {
        guard let agent = activeAgent, !agent.isShell else { return nil }
        return agent
    }

    private var canJump: Bool {
        agentDirectory != nil && onSelectAgent != nil
    }

    var body: some View {
        VStack(spacing: 0) {
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
                // An ended session keeps its last screen readable — the
                // quiet bottom bar says what happened; only a session that
                // never attached (or died unrecoverably) gets the card.
                if controller.needsConnectionConfiguration, controller.connectionState != .ended {
                    disconnectedPrompt
                }
            }
            // Nominal is silence (#54): the identity dot already says
            // connected. When something needs saying the banner floats
            // *over* the surface — in the layout it made the terminal's
            // height connection-state-dependent, so every reconnect flap
            // re-flowed the grid and resized the Mac's pty twice. Final
            // states speak from the bottom bar instead, never over the
            // transcript.
            .overlay(alignment: .top) {
                if !isFinalState, controller.connectionState != .connected || controller.errorMessage != nil {
                    connectionBanner
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
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // A final state has nothing to type into: the key row and
            // composer would be a disabled lie. One quiet bar replaces
            // them and the transcript becomes the readable artifact (#54).
            if isFinalState {
                finalStateBar
            } else {
                terminalControls
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            keyboardUp = false
        }
        .sheet(isPresented: $showingJump) {
            if let agentDirectory, let onSelectAgent {
                JumpToSheet(
                    agentDirectory: agentDirectory,
                    currentPaneID: controller.currentPaneID,
                    onSelect: onSelectAgent
                )
                .presentationDetents([.medium, .large])
            }
        }
        #if DEBUG
        // Renderer stress corpus (MOCHA_DEV_RENDERER_STRESS_CHUNKS): replayed
        // into the renderer on top of whatever the pane itself prints.
        .task {
            guard let chunks = developmentBootstrap.rendererStressChunks else { return }
            while !Task.isCancelled {
                for chunk in chunks {
                    guard !Task.isCancelled else { return }
                    controller.renderDevelopmentOutput(chunk)
                    await Task.yield()
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        #endif
    }

    private func identityHeader(_ agent: AgentSummary) -> some View {
        // In the terminal the dot beside the name is the *connection*:
        // green means live, and the banner row never has to exist for the
        // nominal case. Agent status lives on the home; here the transcript
        // itself shows what the agent is doing.
        let location = agent.isShell ? HomeGrouping.projectName(of: agent.cwd) : agent.projectName
        return VStack(spacing: 1) {
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 7, height: 7)
                Text(agent.displayName)
                    .font(.subheadline.weight(.semibold))
            }
            Text(location)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.displayName), \(location), \(controller.connectionState.accessibilityDescription)")
        .accessibilityIdentifier("terminal.identity")
    }

    // Ended and failed are conclusions, not conditions to report.
    private var isFinalState: Bool {
        controller.connectionState == .ended || controller.connectionState == .failed
    }

    // Ended is not an error: a grey dot and plain words. Red stays
    // reserved for a session that actually failed.
    private var finalStateBar: some View {
        let ended = controller.connectionState == .ended
        return HStack(spacing: 8) {
            Circle()
                .fill(ended ? MochaTheme.statusIdle : MochaTheme.statusBlocked)
                .frame(width: 7, height: 7)
            Text(
                ended
                    ? "This session ended on your Mac — its last screen stays readable."
                    : [controller.connectionState.accessibilityDescription, controller.errorMessage]
                        .compactMap { $0 }
                        .joined(separator: " — ")
            )
            .font(.caption)
            .foregroundStyle(MochaTheme.textSecondary)
            .lineLimit(2)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(MochaTheme.card)
        .overlay(alignment: .top) {
            Rectangle().fill(MochaTheme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("terminal.status")
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
        // Liquid Glass chrome (owner call, 2026-09-01): the system
        // material, not web glassmorphism — the bar reads as glass over
        // the terminal's black.
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(MochaTheme.hairline).frame(height: 1)
        }
    }

    private var liveTypingRow: some View {
        HStack(spacing: 8) {
            // Not the "Done" green: live typing armed is an attention
            // state, and attention is amber.
            Circle()
                .fill(MochaTheme.accent)
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
                    promptTarget == nil ? "Type a command…" : "Message \(promptTarget?.displayName ?? "the agent")…",
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
                    in: RoundedRectangle(cornerRadius: MochaTheme.wellRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MochaTheme.wellRadius, style: .continuous)
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
                    .foregroundStyle(MochaTheme.statusBlocked)
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
                // Clustered like a keyboard (#54): modifier, named keys,
                // arrows, then actions — grouped by gap, not dividers.
                HStack(spacing: 14) {
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

                    HStack(spacing: 6) {
                        ForEach(TerminalQuickKey.commandCluster) { key in
                            keyButton(key)
                        }
                    }

                    HStack(spacing: 6) {
                        ForEach(TerminalQuickKey.arrowCluster) { key in
                            // Arrows repeat on hold, like hardware.
                            keyButton(key)
                                .buttonRepeatBehavior(.enabled)
                        }
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
            // The row scrolls; say so — content dissolves at the trailing
            // edge, but only while keys are actually off-screen there.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 4
            } action: { _, hasMore in
                keyRowHasMore = hasMore
            }
            .mask(
                HStack(spacing: 0) {
                    Rectangle().fill(Color.black)
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: keyRowHasMore ? 22 : 0)
                }
                .animation(.easeOut(duration: 0.15), value: keyRowHasMore)
            )

            // Offered exactly while a keyboard is up — the one true signal;
            // mode flags left it dead in live mode after a dismiss and
            // missing when the surface raised the keyboard from UIKit (#54).
            if keyboardUp {
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
    }

    private func keyButton(_ key: TerminalQuickKey) -> some View {
        Button {
            controller.sendQuickKey(key)
            refocusAfterKey()
        } label: {
            Text(key.face)
        }
        .buttonStyle(TerminalKeyStyle())
        .disabled(!controller.connectionState.canSubmitInput)
        .accessibilityLabel(quickKeyAccessibilityLabel(key))
    }

    // Quick keys never steal the typing target: they refocus the terminal
    // only while live typing is the active mode.
    private func refocusAfterKey() {
        if inputMode == .live {
            controller.bridge.focusTerminal()
        }
    }

    // Herdr agents receive the composer through the structured prompt
    // endpoint; plain terminals get bracketed-paste text plus one explicit
    // return. Text clears only after a confirmed hand-off.
    private func sendComposer() {
        let text = composerText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        composerError = nil
        if let agent = promptTarget, let agentDirectory {
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

    // The honest not-attached state: the controller gave the pane up (it no
    // longer exists, the token was refused, the pty exited) and the banner
    // above carries the reason. Nothing here retries; opening the agent
    // again from the home starts a fresh attach.
    private var disconnectedPrompt: some View {
        ContentUnavailableView {
            Label("Not attached", systemImage: "terminal")
        } description: {
            Text("This agent's terminal is not attached. Go back and open it again from the home.")
        }
        .foregroundStyle(.white)
        .padding()
        .accessibilityIdentifier("terminal.disconnected")
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
            // Liquid Glass caps (owner call, 2026-09-01): the system glass
            // with its own interactive press response; the armed ctrl latch
            // tints the glass amber. Press still seats the cap half a
            // point — glass with a hint of mechanism.
            .glassEffect(
                armed
                    ? .regular.tint(MochaTheme.accent).interactive()
                    : .regular.interactive(),
                in: RoundedRectangle(cornerRadius: MochaTheme.wellRadius, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .offset(y: configuration.isPressed ? 0.5 : 0)
            .contentShape(RoundedRectangle(cornerRadius: MochaTheme.wellRadius, style: .continuous))
            // The single cheapest expensive-feeling change in the app: keys
            // tick when they land.
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in
                pressed
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: armed)
    }

    private var faceColor: Color {
        if armed { return MochaTheme.accentInk }
        return isEnabled ? MochaTheme.textPrimary : MochaTheme.textPrimary.opacity(0.3)
    }
}

#Preview {
    NavigationStack {
        TerminalSessionView(controller: TerminalSessionController())
    }
}
