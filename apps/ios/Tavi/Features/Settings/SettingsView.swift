import LocalAuthentication
import SwiftUI

// Settings (#51). Tavi's job is a 20–60 s check-in, so the list stays
// short and each item answers a real anxiety. The skeleton is the issue's
// researched structure: Terminal, Security, Privacy — not a root tab.
// Deliberately absent: themes, font families, keyboard layouts (terminal-
// emulator territory; the terminal is Tavi's fallback).
struct SettingsView: View {
    let fleet: HostFleet
    // Forgets one computer by id; the others stay paired (#50).
    let onForget: (String) -> Void
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
    // app, not security. Asked in `.task`, never in the initialiser, which
    // SwiftUI re-runs on every redraw of the parent (#68, #69); nil until
    // asked, so an unchecked lock is never drawn as an unavailable one.
    @State private var lockAvailable: Bool?
    // The computer whose "This iPhone" sheet is open.
    @State private var managing: HostFleet.Entry?

    var body: some View {
        NavigationStack {
            List {
                terminalSection
                securitySection
                privacySection
            }
            .scrollContentBackground(.hidden)
            .background(TaviTheme.canvas.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings.done")
                }
            }
            .sheet(item: $managing) { entry in
                ManageAccessView(
                    host: entry.host,
                    directory: entry.directory,
                    onForget: { onForget(entry.id) },
                    onRename: { fleet.rename(hostId: entry.id, alias: $0) }
                )
            }
        }
        .task {
            lockAvailable = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        }
        .onChange(of: fontSize) { _, size in
            TerminalFontPreference.save(size)
        }
        // The sheet must not outlive its computer: a removal from any other
        // path would leave a dead directory behind "Unpair".
        .onChange(of: fleet.hosts.map(\.id)) { _, ids in
            if let managing, !ids.contains(managing.id) { self.managing = nil }
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
            .clipShape(RoundedRectangle(cornerRadius: TaviTheme.wellRadius, style: .continuous))
            .accessibilityHidden(true)
            .listRowBackground(TaviTheme.card)

            HStack {
                Text("Font size")
                    .foregroundStyle(TaviTheme.textSecondary)
                Spacer()
                Text("\(TerminalFontPreference.label(for: fontSize)) pt")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(TaviTheme.textPrimary)
            }
            // The slider below speaks this row's content as its value;
            // repeating it here would only add VoiceOver noise.
            .accessibilityHidden(true)
            .listRowBackground(TaviTheme.card)

            Slider(
                value: $fontSize,
                in: TerminalFontPreference.range,
                step: TerminalFontPreference.step
            ) {
                Text("Terminal font size")
            } minimumValueLabel: {
                Image(systemName: "textformat.size.smaller")
                    .foregroundStyle(TaviTheme.textSecondary)
            } maximumValueLabel: {
                Image(systemName: "textformat.size.larger")
                    .foregroundStyle(TaviTheme.textSecondary)
            }
            // The grid is the payoff of the trade-off, so VoiceOver hears
            // it while dragging, not just the point size.
            .accessibilityValue(sliderSpokenValue)
            .accessibilityIdentifier("settings.fontSize")
            .listRowBackground(TaviTheme.card)

            HStack {
                Text("Terminal grid")
                    .foregroundStyle(TaviTheme.textSecondary)
                Spacer()
                Text(gridReadout)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(TaviTheme.textPrimary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Terminal grid")
            .accessibilityValue(gridSpokenValue)
            .accessibilityIdentifier("settings.gridReadout")
            .listRowBackground(TaviTheme.card)
        } header: {
            Text("Terminal")
        } footer: {
            Text("A smaller font gives the agent a bigger window while you are connected. Pinch the terminal to change this too.")
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

    @ViewBuilder
    private var securitySection: some View {
        Section {
            Toggle("Require Face ID to open", isOn: $faceIDLock)
                .foregroundStyle(TaviTheme.textPrimary)
                .disabled(lockAvailable != true)
                .accessibilityIdentifier("settings.faceIDLock")
                .listRowBackground(TaviTheme.card)

        } header: {
            Text("Security")
        } footer: {
            Text(securityFooter)
        }

        // One row per paired computer (#50): what it is called and how it
        // is doing; the row opens "This iPhone" for that computer alone.
        Section {
            ForEach(fleet.entries) { entry in
                Button {
                    managing = entry
                } label: {
                    HStack(spacing: 10) {
                        Text(entry.host.displayName)
                            .foregroundStyle(TaviTheme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        HostHealthLabel(
                            health: entry.directory.health,
                            latencyMilliseconds: entry.directory.latencyMilliseconds
                        )
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(TaviTheme.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.host.\(entry.id)")
                .listRowBackground(TaviTheme.card)
            }
            Button {
                onPairAnother()
            } label: {
                Label("Pair a computer", systemImage: "qrcode.viewfinder")
                    .foregroundStyle(TaviTheme.textPrimary)
            }
            .accessibilityIdentifier("settings.pairAnother")
            .listRowBackground(TaviTheme.card)
        } header: {
            Text("Paired computers")
        } footer: {
            if fleet.isConfigured {
                Text("Each computer is paired on its own. Unpairing one leaves the others as they are.")
            }
        }
    }

    // Two sentences at most (#54); the paired-computer rows explain themselves.
    private var securityFooter: String {
        var sentences = ["Face ID protects the app, not your computers: anyone who unlocks Tavi can type into your agents."]
        if lockAvailable == false {
            sentences.append("Face ID or a passcode must be set up on this iPhone before the lock can be turned on.")
        }
        return sentences.joined(separator: " ")
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            Text("Tavi has no analytics and no servers of its own. Your terminals, prompts, and credentials travel only between this iPhone and your paired computers over your Tailscale network. Previews shown on the home are stripped of terminal control sequences before display.")
                .font(.footnote)
                .foregroundStyle(TaviTheme.textSecondary)
                .listRowBackground(TaviTheme.card)
                .accessibilityIdentifier("settings.privacy")
        } header: {
            Text("Privacy")
        }
    }
}

#Preview {
    SettingsView(
        fleet: HostFleet(),
        onForget: { _ in },
        onPairAnother: {}
    )
    .preferredColorScheme(.dark)
}
