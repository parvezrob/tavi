import SwiftUI
import UIKit

extension TerminalSessionView {
    // Opaque charcoal input bar in the terminal's own visual world: a key
    // row styled as key caps, then a single input surface — the composer
    // or the live-typing hint, never both.
    var terminalControls: some View {
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
        // Opaque on purpose: a material here live-blurs the Metal surface
        // beneath it, which taxed an iPhone 12 Pro into visible typing
        // latency. The glass lives on the caps (over this opaque bar) and
        // in the nav chip — where it costs nothing per keystroke.
        .background(TaviTheme.card)
        .overlay(alignment: .top) {
            Rectangle().fill(TaviTheme.hairline).frame(height: 1)
        }
    }

    private var liveTypingRow: some View {
        HStack(spacing: 8) {
            // Not the "Done" green: live typing armed is an attention
            // state, and attention is amber.
            Circle()
                .fill(TaviTheme.accent)
                .frame(width: 6, height: 6)
            Text("Live typing — keys go straight to the terminal")
                .font(.caption)
                .foregroundStyle(TaviTheme.textSecondary)
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
        dictation.cancel()
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
                    TaviTheme.well,
                    in: RoundedRectangle(cornerRadius: TaviTheme.wellRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TaviTheme.wellRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .accessibilityIdentifier("terminal.composer")

                attachButton

                dictationButton

                Button {
                    sendComposer()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(
                    composerSending
                        || dictation.state.isActive
                        || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !controller.connectionState.canSubmitInput
                )
                .accessibilityLabel("Send")
                .accessibilityIdentifier("terminal.composerSend")
            }
            if let composerError {
                Text(composerError)
                    .font(.caption)
                    .foregroundStyle(TaviTheme.statusBlocked)
            } else if let composerNote {
                Text(composerNote)
                    .font(.caption)
                    .foregroundStyle(TaviTheme.textSecondary)
                    .accessibilityIdentifier("terminal.composerNote")
            } else if let caption = dictationCaption {
                HStack(spacing: 6) {
                    if dictation.state == .listening {
                        DictationLevelMeter(level: dictation.inputLevel)
                    }
                    Text(caption.text)
                        .font(.caption)
                        .foregroundStyle(caption.isFailure ? TaviTheme.statusBlocked : TaviTheme.textSecondary)
                        .lineLimit(2)
                    if caption.offersSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Settings", destination: url)
                            .font(.caption.weight(.semibold))
                    }
                }
                .accessibilityIdentifier("terminal.dictationStatus")
            }
        }
        .onDisappear { dictation.cancel() }
        // Hand the input surface over cleanly: the keyboard goes away while
        // the mic listens (it is dead weight over the transcript), and comes
        // back the moment dictation ends so the words are edit-ready. A
        // light tap marks both edges so the ear and the thumb agree.
        .onChange(of: dictation.state) { previous, current in
            switch (previous, current) {
            case (_, .listening):
                composerFocused = false
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case (.listening, .idle), (.listening, .failed):
                composerFocused = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            default:
                break
            }
        }
    }

    private var quickKeyRow: some View {
        HStack(spacing: 8) {
            // A mode, not a key (#54): the chip names the mode you are in —
            // amber "live" when keys stream to the pty, quiet "compose"
            // when text drafts locally. Tap to switch.
            Button {
                if inputMode == .live {
                    switchToCompose()
                } else {
                    switchToLive()
                }
            } label: {
                Text(inputMode == .live ? "live" : "compose")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .buttonStyle(TerminalKeyStyle(armed: inputMode == .live))
            .disabled(!controller.connectionState.canSubmitInput)
            .accessibilityLabel(
                inputMode == .live ? "Live typing on, switch to composer" : "Compose mode on, switch to live typing"
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
                    composerNote = nil
                }
            }
        } else {
            controller.sendComposedText(text)
            composerText = ""
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
                    ? .regular.tint(TaviTheme.accent).interactive()
                    : .regular.interactive(),
                in: RoundedRectangle(cornerRadius: TaviTheme.wellRadius, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .offset(y: configuration.isPressed ? 0.5 : 0)
            .contentShape(RoundedRectangle(cornerRadius: TaviTheme.wellRadius, style: .continuous))
            // The single cheapest expensive-feeling change in the app: keys
            // tick when they land.
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in
                pressed
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: armed)
    }

    private var faceColor: Color {
        if armed { return TaviTheme.accentInk }
        return isEnabled ? TaviTheme.textPrimary : TaviTheme.textPrimary.opacity(0.3)
    }
}
