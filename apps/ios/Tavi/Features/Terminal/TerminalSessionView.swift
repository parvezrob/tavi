import PhotosUI
import SwiftUI
import UIKit

// Exactly one typing target exists at any moment: the composer drafts a
// deliberate message locally, live mode sends every keystroke straight to
// the pty. The Keyboard key (or tapping the terminal) switches modes.
enum TerminalInputMode {
    case compose
    case live
}

struct TerminalSessionView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingJump = false
    // The attached pane's row, fed by the observer child below: nothing on
    // this screen reads the agent list itself, so the list is not one of its
    // dependencies (#68 phone 5).
    @State var identity: AgentSummary?
    // Files (#25 #57 #61): what this agent changed, mentioned, or has.
    @State private var showingFiles = false
    // Preview (#58): the dev server this agent started, on the phone. The
    // button lights up when the transcript names a localhost port — pure
    // text, so it costs the computer nothing until the tap.
    @State private var showingPreview = false
    @State private var showingRename = false
    @State private var renameDraft = ""
    @State private var renameError: String?
    @State var composerText = ""
    @State var composerError: String?
    // An image attached from the composer (#88): picked, shrunk, uploaded,
    // its path appended to the text. The note says where it went.
    @State var pickedImage: PhotosPickerItem?
    @State var attachingImage = false
    @State var composerNote: String?
    @State var composerSending = false
    // Voice lands in compose mode only (#56): the session lives inside the
    // composer and edits its draft, nothing else. Live mode has no mic.
    @State var dictation = DictationSession(makeEngine: { SpeechDictationEngine() })
    @State var inputMode: TerminalInputMode = .compose
    // The real keyboard signal: the Ghostty surface raises the keyboard
    // from UIKit (a tap on it becomes first responder) entirely outside
    // SwiftUI state, so mode flags alone cannot gate the dismiss control.
    @State var keyboardUp = false
    // Trailing fade only while keys are actually off-screen; a permanent
    // fade reads as a disabled last key.
    @State var keyRowHasMore = true
    @FocusState var composerFocused: Bool

    let controller: TerminalSessionController
    // The events mirror of the computer this terminal is attached to,
    // behind the identity header, rename, and prompt delivery; nil only in
    // previews, which keep the generic chrome.
    let agentDirectory: AgentDirectory?
    // The attached computer's name when several are paired (#50): the
    // header is the only thing that says which machine this screen is,
    // and Jump-to can move it across machines.
    let computerName: String?
    // Every paired computer, for the Jump-to sheet (#50).
    private let jumpSources: [JumpSource]
    private let onSelectAgent: ((AgentSummary) -> Void)?
    private let developmentBootstrap: TerminalDevelopmentBootstrap

    init(
        controller: TerminalSessionController,
        agentDirectory: AgentDirectory? = nil,
        computerName: String? = nil,
        jumpSources: [JumpSource]? = nil,
        onSelectAgent: ((AgentSummary) -> Void)? = nil,
        developmentBootstrap: TerminalDevelopmentBootstrap = .launchEnvironment()
    ) {
        self.developmentBootstrap = developmentBootstrap
        self.controller = controller
        self.agentDirectory = agentDirectory
        self.computerName = computerName
        self.jumpSources = jumpSources
            ?? agentDirectory.map { [JumpSource(hostId: $0.hostId, name: "", directory: $0)] }
            ?? []
        self.onSelectAgent = onSelectAgent
    }

    // Host + pane of the attached agent (#50).
    private var currentTarget: AgentTarget? {
        controller.currentPaneID.map { AgentTarget(hostId: agentDirectory?.hostId ?? "", paneId: $0) }
    }

    // The agent the composer should *prompt*. A shell pane is a herdr agent
    // for listing and attaching, but its input is commands (#43), so it is
    // deliberately nil here and takes the plain-terminal send path.
    var promptTarget: AgentSummary? {
        guard let agent = identity, !agent.isShell else { return nil }
        return agent
    }

    private var canJump: Bool {
        !jumpSources.isEmpty && onSelectAgent != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            TerminalIdentityObserver(
                directory: agentDirectory,
                paneID: controller.currentPaneID,
                identity: $identity
            )
            AgentTerminalView(
                bridge: controller.bridge,
                isActive: scenePhase == .active,
                onGridSizeChange: controller.terminalGridDidChange,
                onRendererReady: controller.terminalRendererDidAttach,
                onRendererFailure: controller.rendererDidFail,
                onTranscript: controller.transcriptDidChange
            )
            // Jump-to points this same screen at another pane. A new
            // session gets a new surface, so no half-parsed escape
            // sequence or scrollback from the previous pane survives into
            // it; an ordinary reconnect keeps the id and the surface (#108).
            .id(controller.sessionID)
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
                // A session that ended or was taken over keeps its last
                // screen readable — the quiet bottom bar says what happened;
                // only one that never attached (or died unrecoverably) gets
                // the card.
                if controller.needsConnectionConfiguration,
                   controller.connectionState != .ended,
                   controller.connectionState != .superseded {
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
        .navigationTitle(identity == nil ? "Terminal" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let agent = identity {
                ToolbarItem(placement: .principal) {
                    // The identity is a glass chip, and it does something:
                    // tapping it opens Jump to — switching panes starts at
                    // the name of the one you're in (#54).
                    Button {
                        if canJump { showingJump = true }
                    } label: {
                        identityHeader(agent)
                            .padding(.horizontal, TaviTheme.Spacing.card)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    // Naming lives on the pane's own page (#55): hold the
                    // chip and the rename sheet opens directly — no context
                    // menu layer, which is unreliable on nav-bar items for
                    // fingers and tests alike.
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            renameDraft = agent.userTabName ?? ""
                            showingRename = true
                        }
                    )
                }
            }
            if identity != nil, agentDirectory != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Preview", systemImage: "globe") {
                        showingPreview = true
                    }
                    .tint(controller.mentionedPorts.isEmpty ? nil : TaviTheme.accent)
                    .accessibilityIdentifier(controller.mentionedPorts.isEmpty ? "terminal.preview" : "terminal.preview.available")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Files", systemImage: "doc.text.magnifyingglass") {
                        showingFiles = true
                    }
                    .accessibilityIdentifier("terminal.files")
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
        .sheet(isPresented: $showingPreview) {
            if let agent = identity {
                PreviewSheet(
                    agent: agent,
                    client: agentDirectory?.previewClient,
                    computerName: computerName,
                    mentionedPorts: controller.mentionedPorts
                )
            }
        }
        .sheet(isPresented: $showingFiles) {
            if let agent = identity {
                FilesSheet(
                    agent: agent,
                    client: agentDirectory?.filesClient,
                    computerName: computerName,
                    transcript: controller.latestTranscript,
                    initialTab: .mentioned
                )
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
        .alert("Name this pane", isPresented: $showingRename) {
            TextField("What is it working on?", text: $renameDraft)
            Button("Save") {
                let name = renameDraft.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, let agent = identity, let agentDirectory else { return }
                Task {
                    renameError = await agentDirectory.renameTab(tabId: agent.tabId, label: name)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your name for this tab shows on the home, here, and in Jump to.")
        }
        .alert(
            "Couldn't rename",
            isPresented: Binding(
                get: { renameError != nil },
                set: { if !$0 { renameError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { renameError = nil }
        } message: {
            Text(renameError ?? "")
        }
        .sheet(isPresented: $showingJump) {
            if !jumpSources.isEmpty, let onSelectAgent {
                JumpToSheet(
                    sources: jumpSources,
                    currentTarget: currentTarget,
                    onSelect: onSelectAgent
                )
                .presentationDetents([.medium, .large])
            }
        }
        #if DEBUG
        // Renderer stress corpus (TAVI_DEV_RENDERER_STRESS_CHUNKS): replayed
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

    private var isFinalState: Bool {
        controller.connectionState.isFinal
    }

    // Ended and taken over are not errors: a grey dot and plain words. Red
    // stays reserved for a session that actually failed.
    private var finalStateBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.connectionState == .failed ? TaviTheme.statusBlocked : TaviTheme.statusIdle)
                .frame(width: 7, height: 7)
            Text(finalStateSentence)
                .font(.caption)
                .foregroundStyle(TaviTheme.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, TaviTheme.Spacing.card)
        .padding(.vertical, TaviTheme.Spacing.snug)
        .background(TaviTheme.card)
        .overlay(alignment: .top) {
            Rectangle().fill(TaviTheme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("terminal.status")
    }

    // The two quiet endings each say what happened and what is still true;
    // anything else falls back to the state plus whatever went wrong.
    private var finalStateSentence: String {
        switch controller.connectionState {
        case .ended:
            "This session ended on \(computerName ?? "the computer") — its last screen stays readable."
        case .superseded:
            "Another connection took over. Open this terminal again to reconnect."
        default:
            [controller.connectionState.accessibilityDescription, controller.errorMessage]
                .compactMap { $0 }
                .joined(separator: " — ")
        }
    }

    private var connectionBanner: some View {
        VStack(spacing: 4) {
            HStack(spacing: 7) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 7, height: 7)
                Text(controller.connectionState.accessibilityDescription)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(TaviTheme.textSecondary)
                Spacer(minLength: 8)
            }
            if let error = controller.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(TaviTheme.statusBlocked)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, TaviTheme.Spacing.snug)
        .padding(.vertical, TaviTheme.Spacing.tight)
        .background(TaviTheme.card)
        .overlay(alignment: .bottom) {
            Rectangle().fill(TaviTheme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("terminal.status")
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
}

#Preview {
    NavigationStack {
        TerminalSessionView(controller: TerminalSessionController())
    }
}
