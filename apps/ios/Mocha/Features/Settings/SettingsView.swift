import LocalAuthentication
import SwiftUI

// Settings (#51). Mocha's job is a 20–60 s check-in, so the list stays
// short and each item answers a real anxiety. The skeleton is the issue's
// researched structure: Terminal, Security, Privacy — not a root tab.
// Deliberately absent: themes, font families, keyboard layouts (terminal-
// emulator territory; the terminal is Mocha's fallback).
struct SettingsView: View {
    let hostAddress: String
    let directory: AgentDirectory
    let onForget: () -> Void
    let onPairAnother: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppLock.storageKey) private var faceIDLock = false
    @State private var fontSize = TerminalFontPreference.current()
    // The grid the preview surface reports at the chosen size, and the grid
    // it reported when the sheet opened — shown as "44 × 22 → 58 × 30" so
    // the trade-off is visible in honest numbers, not adjectives.
    @State private var projectedGrid: TerminalGridSize?
    @State private var openingGrid: TerminalGridSize?
    // Before any terminal has opened, the projection runs against an
    // estimated viewport; the readout says "≈" instead of posing as fact.
    @State private var hasRealViewport = TerminalViewportRecord.load() != nil
    // The lock cannot be turned on where device-owner authentication can
    // never succeed (no passcode set): an uncheckable lock is a bricked
    // app, not security.
    @State private var lockAvailable = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    @State private var showingManageAccess = false

    var body: some View {
        NavigationStack {
            List {
                terminalSection
                securitySection
                privacySection
            }
            .scrollContentBackground(.hidden)
            .background(MochaTheme.canvas.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings.done")
                }
            }
            .sheet(isPresented: $showingManageAccess) {
                ManageAccessView(
                    record: PairedHostRecord.load(),
                    hostAddress: hostAddress,
                    directory: directory,
                    onForget: onForget,
                    onPairAnother: onPairAnother
                )
            }
        }
        .onChange(of: fontSize) { _, size in
            TerminalFontPreference.save(size)
        }
    }

    // MARK: - Terminal

    private var terminalSection: some View {
        Section {
            // A real Ghostty surface laid out at the remembered terminal
            // viewport and clipped to this box: the visible text is the
            // actual rendering at the chosen size, and the grid it reports
            // is exactly what a full terminal would get.
            TerminalFontPreviewView(
                fontSize: fontSize,
                isActive: scenePhase == .active
            ) { grid in
                if openingGrid == nil { openingGrid = grid }
                projectedGrid = grid
            }
            .frame(height: 128)
            .clipShape(RoundedRectangle(cornerRadius: MochaTheme.wellRadius, style: .continuous))
            .accessibilityHidden(true)
            .listRowBackground(MochaTheme.card)

            HStack {
                Text("Font size")
                    .foregroundStyle(MochaTheme.textSecondary)
                Spacer()
                Text("\(TerminalFontPreference.label(for: fontSize)) pt")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(MochaTheme.textPrimary)
            }
            // The slider below speaks this row's content as its value;
            // repeating it here would only add VoiceOver noise.
            .accessibilityHidden(true)
            .listRowBackground(MochaTheme.card)

            Slider(
                value: $fontSize,
                in: TerminalFontPreference.range,
                step: TerminalFontPreference.step
            ) {
                Text("Terminal font size")
            } minimumValueLabel: {
                Image(systemName: "textformat.size.smaller")
                    .foregroundStyle(MochaTheme.textSecondary)
            } maximumValueLabel: {
                Image(systemName: "textformat.size.larger")
                    .foregroundStyle(MochaTheme.textSecondary)
            }
            // The grid is the payoff of the trade-off, so VoiceOver hears
            // it while dragging, not just the point size.
            .accessibilityValue(sliderSpokenValue)
            .accessibilityIdentifier("settings.fontSize")
            .listRowBackground(MochaTheme.card)

            HStack {
                Text("Terminal grid")
                    .foregroundStyle(MochaTheme.textSecondary)
                Spacer()
                Text(gridReadout)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(MochaTheme.textPrimary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Terminal grid")
            .accessibilityValue(gridSpokenValue)
            .accessibilityIdentifier("settings.gridReadout")
            .listRowBackground(MochaTheme.card)
        } header: {
            Text("Terminal")
        } footer: {
            Text("A smaller font gives the Mac a bigger window while you are connected. Pinch the terminal to change this too.")
        }
    }

    private var gridReadout: String {
        guard let projectedGrid else { return "—" }
        let prefix = hasRealViewport ? "" : "≈ "
        if let openingGrid, openingGrid != projectedGrid {
            return "\(prefix)\(openingGrid.columns) × \(openingGrid.rows) → \(projectedGrid.columns) × \(projectedGrid.rows)"
        }
        return "\(prefix)\(projectedGrid.columns) × \(projectedGrid.rows)"
    }

    // What VoiceOver says for the readout row: words, not symbol names.
    private var gridSpokenValue: String {
        guard let projectedGrid else { return "not measured yet" }
        let prefix = hasRealViewport ? "" : "about "
        if let openingGrid, openingGrid != projectedGrid {
            return "\(prefix)\(openingGrid.columns) by \(openingGrid.rows), changing to \(projectedGrid.columns) by \(projectedGrid.rows)"
        }
        return "\(prefix)\(projectedGrid.columns) by \(projectedGrid.rows)"
    }

    private var sliderSpokenValue: String {
        let points = "\(TerminalFontPreference.label(for: fontSize)) points"
        guard let projectedGrid else { return points }
        let prefix = hasRealViewport ? "" : "about "
        return "\(points), \(prefix)\(projectedGrid.columns) by \(projectedGrid.rows)"
    }

    // MARK: - Security

    private var securitySection: some View {
        Section {
            Toggle("Require Face ID to open", isOn: $faceIDLock)
                .foregroundStyle(MochaTheme.textPrimary)
                .disabled(!lockAvailable)
                .accessibilityIdentifier("settings.faceIDLock")
                .listRowBackground(MochaTheme.card)

            if directory.isConfigured {
                Button {
                    showingManageAccess = true
                } label: {
                    HStack {
                        Text("This iPhone")
                            .foregroundStyle(MochaTheme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(MochaTheme.textSecondary)
                    }
                }
                .accessibilityIdentifier("settings.thisIPhone")
                .listRowBackground(MochaTheme.card)
            }
        } header: {
            Text("Security")
        } footer: {
            Text(securityFooter)
        }
    }

    private var securityFooter: String {
        var sentences = ["Face ID protects the app, not the Mac: anyone who unlocks Mocha can type into your agents."]
        if !lockAvailable {
            sentences.append("Face ID or a passcode must be set up on this iPhone before the lock can be turned on.")
        }
        if directory.isConfigured {
            sentences.append("This iPhone shows the paired Mac and lets you unpair.")
        }
        return sentences.joined(separator: " ")
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            Text("Mocha has no analytics and no servers of its own. Your terminals, prompts, and credentials travel only between this iPhone and your paired Mac over your tailnet. Previews shown on the home are stripped of terminal control sequences before display.")
                .font(.footnote)
                .foregroundStyle(MochaTheme.textSecondary)
                .listRowBackground(MochaTheme.card)
                .accessibilityIdentifier("settings.privacy")
        } header: {
            Text("Privacy")
        }
    }
}

#Preview {
    SettingsView(
        hostAddress: "https://mac.tailnet.ts.net",
        directory: AgentDirectory(),
        onForget: {},
        onPairAnother: {}
    )
    .preferredColorScheme(.dark)
}
