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

            VStack(alignment: .leading, spacing: 6) {
                ForEach(dialog.options) { option in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: option.selected ? "largecircle.fill.circle" : "circle")
                            .font(.caption)
                            .foregroundStyle(option.selected ? MochaTheme.statusBlocked : MochaTheme.textSecondary)
                            .padding(.top, 2)
                        Text("\(option.index). \(option.label)")
                            .font(.footnote)
                            .foregroundStyle(MochaTheme.textSecondary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                MochaTheme.well,
                in: RoundedRectangle(cornerRadius: MochaTheme.wellRadius, style: .continuous)
            )

            VStack(spacing: 10) {
                Button {
                    Task { await decide(.approve) }
                } label: {
                    decisionLabel("Approve", systemImage: "checkmark", busy: inFlight == .approve)
                }
                .buttonStyle(.borderedProminent)
                .tint(MochaTheme.statusDone)
                .accessibilityIdentifier("decision.approve")

                Button {
                    Task { await decide(.deny) }
                } label: {
                    decisionLabel("Deny", systemImage: "xmark", busy: inFlight == .deny)
                }
                .buttonStyle(.bordered)
                .tint(MochaTheme.statusBlocked)
                .accessibilityIdentifier("decision.deny")
            }
            .disabled(inFlight != nil)

            Text("Approve confirms the highlighted choice. Deny cancels the prompt. For any other option, open the terminal.")
                .font(.caption2)
                .foregroundStyle(MochaTheme.textSecondary.opacity(0.8))
        }
    }

    private func decisionLabel(_ title: String, systemImage: String, busy: Bool) -> some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage)
            }
            Text(title).fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
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
