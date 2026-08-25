import SwiftUI

// Approve or deny a waiting permission without entering the terminal (#23).
// The sheet reads the live dialog from the host, shows the real question and
// choices, and offers Approve / Deny with Open terminal as the escape hatch.
// The host re-reads the pane before acting, so a dialog that resolved while
// this sheet was open is reported honestly rather than answered blindly.
struct PermissionDecisionSheet: View {
    let agent: AgentSummary
    let directory: AgentDirectory
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
            .background(MochaTheme.canvas.ignoresSafeArea())
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(agent.displayName)
                .font(.headline)
                .foregroundStyle(MochaTheme.textPrimary)
            Text(agent.projectName)
                .font(.footnote)
                .foregroundStyle(MochaTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Reading the prompt…")
                    .font(.callout)
                    .foregroundStyle(MochaTheme.textSecondary)
            }
            .accessibilityIdentifier("decision.loading")

        case let .dialog(dialog):
            dialogBody(dialog)

        case .resolved:
            outcomeCard(
                icon: "checkmark.circle",
                tint: MochaTheme.statusDone,
                title: "Already resolved",
                message: "This prompt was answered before your decision landed. Nothing was sent."
            )
            .accessibilityIdentifier("decision.resolved")

        case let .failed(message):
            outcomeCard(
                icon: "exclamationmark.triangle",
                tint: MochaTheme.statusBlocked,
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
                Text(dialog.prompt)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(MochaTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

            Button {
                Task { await decide(.deny) }
            } label: {
                HStack(spacing: 8) {
                    if inFlight == .deny {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "xmark")
                    }
                    Text("Cancel (Esc)").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .tint(MochaTheme.statusBlocked)
            .disabled(inFlight != nil)
            .accessibilityIdentifier("decision.deny")

            Text("Tap a choice to send it. Options that grant standing access are marked — they stop the prompts from coming back.")
                .font(.caption2)
                .foregroundStyle(MochaTheme.textSecondary.opacity(0.8))
        }
    }

    private func optionButton(_ option: PermissionDialogOption) -> some View {
        let elevated = Self.grantsStandingAccess(option.label)
        let tint = elevated ? MochaTheme.statusBlocked : MochaTheme.statusDone
        return Button {
            Task { await decide(.option(option.index)) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if inFlight == .option(option.index) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: elevated ? "exclamationmark.shield" : "\(option.index).circle")
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(MochaTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if option.selected || elevated {
                        Text(elevated ? "Grants standing access" : "Default")
                            .font(.caption2)
                            .foregroundStyle(tint)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                MochaTheme.well,
                in: RoundedRectangle(cornerRadius: MochaTheme.wellRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MochaTheme.wellRadius, style: .continuous)
                    .strokeBorder(option.selected ? tint.opacity(0.7) : MochaTheme.hairline, lineWidth: 1)
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
                    .foregroundStyle(MochaTheme.textPrimary)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(MochaTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .mochaCard(stripe: tint)
    }

    private var openTerminalButton: some View {
        Button {
            dismiss()
            onOpenTerminal()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text("Open terminal")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .tint(MochaTheme.textSecondary)
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
