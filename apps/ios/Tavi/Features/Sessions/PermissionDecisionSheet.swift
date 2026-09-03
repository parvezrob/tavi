import SwiftUI

// Approve or deny a waiting permission without entering the terminal (#23).
// The sheet reads the live dialog from the host, shows the real question and
// choices, and offers Approve / Deny with Open terminal as the escape hatch.
// The host re-reads the pane before acting, so a dialog that resolved while
// this sheet was open is reported honestly rather than answered blindly.
struct PermissionDecisionSheet: View {
    let agent: AgentSummary
    let directory: AgentDirectory
    // Named when several computers are paired (#50): a command approved
    // here runs on that machine, and the folder name alone can be shared.
    var computerName: String? = nil
    let onOpenTerminal: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var inFlight: DialogDecision?

    private enum Phase: Equatable {
        case loading
        case dialog(PermissionDialog)
        case resolved
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    content
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(TaviTheme.canvas.ignoresSafeArea())
            .navigationTitle("Needs you")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    // Identity appears once: the eyebrow below carries the agent's name as
    // attribution for the quoted dialog; the header keeps only the place.
    private var header: some View {
        Text([computerName, agent.projectName].compactMap { $0 }.joined(separator: " · "))
            .font(.footnote)
            .foregroundStyle(TaviTheme.textSecondary)
            .accessibilityIdentifier("decision.location")
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Reading the prompt…")
                    .font(.callout)
                    .foregroundStyle(TaviTheme.textSecondary)
            }
            .accessibilityIdentifier("decision.loading")

        case let .dialog(dialog):
            dialogBody(dialog)

        case .resolved:
            outcomeCard(
                icon: "checkmark.circle",
                tint: TaviTheme.statusDone,
                title: "Already resolved",
                message: "This prompt was answered before your decision landed. Nothing was sent."
            )
            .accessibilityIdentifier("decision.resolved")

        case let .failed(message):
            outcomeCard(
                icon: "exclamationmark.triangle",
                tint: TaviTheme.statusBlocked,
                title: "Couldn't act",
                message: message
            )
            .accessibilityIdentifier("decision.failed")
        }

        openTerminalButton
    }

    private func dialogBody(_ dialog: PermissionDialog) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !dialog.prompt.isEmpty {
                // The prompt is the agent's own dialog text ("Security
                // guide", …) quoted verbatim; this line says whose words
                // they are so a raw heading never reads as Tavi's UI (#54).
                Text("\(agent.displayName) is asking")
                    .font(.caption.weight(.semibold))
                    .kerning(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(TaviTheme.textSecondary)
                // Visibly quoted, not just attributed: a raw dialog heading
                // like "Security guide" must never read as Tavi's own UI.
                Text(dialog.prompt)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(TaviTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(TaviTheme.Spacing.snug)
                    .background(
                        TaviTheme.well,
                        in: RoundedRectangle(cornerRadius: TaviTheme.wellRadius, style: .continuous)
                    )
                    .overlay(alignment: .leading) {
                        UnevenRoundedRectangle(
                            topLeadingRadius: TaviTheme.wellRadius,
                            bottomLeadingRadius: TaviTheme.wellRadius
                        )
                        .fill(TaviTheme.textSecondary.opacity(0.5))
                        .frame(width: 2)
                    }
            }

            // Every option the dialog offers is its own button and sends that
            // choice. The highlighted option is marked "default"; options that
            // grant standing permission ("always allow", "don't ask again")
            // are flagged so a consequential pick is never a casual tap.
            VStack(spacing: 8) {
                ForEach(dialog.options) { option in
                    optionButton(option)
                }
            }
            .disabled(inFlight != nil)

            // Cancel answers the dialog (it sends Esc) — a real control in
            // the options' own quiet clothing, subordinate to the amber
            // default but never dressed as a disabled label (#54).
            Button {
                Task { await decide(.deny) }
            } label: {
                HStack(spacing: 6) {
                    if inFlight == .deny {
                        ProgressView().controlSize(.small)
                    }
                    Text("Cancel (Esc)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(TaviTheme.textPrimary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, TaviTheme.Spacing.snug)
                .background(
                    TaviTheme.well,
                    in: RoundedRectangle(cornerRadius: TaviTheme.wellRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TaviTheme.wellRadius, style: .continuous)
                        .strokeBorder(TaviTheme.hairline, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(inFlight != nil)
            .accessibilityIdentifier("decision.deny")

            Text("Tap a choice to send it. Options that grant standing access are marked — they stop the prompts from coming back.")
                .font(.caption2)
                .foregroundStyle(TaviTheme.textSecondary.opacity(0.8))
        }
    }

    // Options are neutral surfaces; the dialog's own default carries the
    // accent, and an option that grants standing access is marked by the
    // shield and its caption — one accent, no green strokes (#54).
    private func optionButton(_ option: PermissionDialogOption) -> some View {
        let elevated = Self.grantsStandingAccess(option.label)
        return Button {
            Task { await decide(.option(option.index)) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if inFlight == .option(option.index) {
                    ProgressView().controlSize(.small)
                } else {
                    // Amber belongs to the default alone; a consequential
                    // option is marked by the shield and a full-strength
                    // caption plus a heavier border — caution keeps its own
                    // channel instead of borrowing the recommendation's.
                    Image(systemName: elevated ? "exclamationmark.shield" : "\(option.index).circle")
                        .foregroundStyle(elevated ? TaviTheme.textPrimary : (option.selected ? TaviTheme.accent : TaviTheme.textSecondary))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label)
                        .font(.subheadline.weight(option.selected ? .semibold : .medium))
                        .foregroundStyle(TaviTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if option.selected || elevated {
                        Text([
                            option.selected ? "Default" : nil,
                            elevated ? "Grants standing access" : nil,
                        ].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(elevated ? TaviTheme.textPrimary : TaviTheme.textSecondary)
                    }
                }
            }
            .padding(TaviTheme.Spacing.card)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                TaviTheme.well,
                in: RoundedRectangle(cornerRadius: TaviTheme.wellRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TaviTheme.wellRadius, style: .continuous)
                    .strokeBorder(
                        option.selected
                            ? TaviTheme.accent.opacity(0.55)
                            : (elevated ? Color.white.opacity(0.25) : TaviTheme.hairline),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("decision.option.\(option.index)")
    }

    private static func grantsStandingAccess(_ label: String) -> Bool {
        let lowered = label.lowercased()
        return lowered.contains("always allow")
            || lowered.contains("don't ask")
            || lowered.contains("dont ask")
            || lowered.contains("always")
    }

    private func outcomeCard(icon: String, tint: Color, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(TaviTheme.textPrimary)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(TaviTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(TaviTheme.Spacing.card)
        .taviCard(stripe: tint)
    }

    // Last in the hierarchy: the fallback for people who want the whole
    // screen, styled as a text action so it never outweighs the choices.
    private var openTerminalButton: some View {
        Button {
            dismiss()
            onOpenTerminal()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text("Open terminal")
            }
            .font(.subheadline)
            .foregroundStyle(TaviTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("decision.openTerminal")
    }

    private func load() async {
        phase = .loading
        switch await directory.fetchDialog(paneId: agent.id) {
        case let .dialog(dialog): phase = .dialog(dialog)
        case .none: phase = .resolved
        case let .failure(message): phase = .failed(message)
        }
    }

    private func decide(_ decision: DialogDecision) async {
        inFlight = decision
        defer { inFlight = nil }
        switch await directory.decide(paneId: agent.id, decision: decision) {
        case .ok:
            dismiss()
        case .stale:
            phase = .resolved
        case let .failure(message):
            phase = .failed(message)
        }
    }
}
