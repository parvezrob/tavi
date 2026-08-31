import SwiftUI

// "Jump to" (screen T1): the Herdr workspace → tab hierarchy inside the
// focused terminal. Tabs with agents switch the terminal to that exact
// pane; agent-less tabs stay visible but inert — plain panes are not
// attachable yet, and pretending otherwise would fake a capability.
struct JumpToSheet: View {
    let agentDirectory: AgentDirectory
    let currentPaneID: String?
    let onSelect: (AgentSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var fetch: HerdrTreeFetch?

    var body: some View {
        NavigationStack {
            Group {
                switch fetch {
                case nil:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failure(let reason):
                    ContentUnavailableView {
                        Label("Herdr Unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(reason)
                    }
                case .tree(let workspaces):
                    treeList(workspaces)
                }
            }
            .background(MochaTheme.canvas)
            .navigationTitle("Jump to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            fetch = await agentDirectory.fetchTree()
        }
        .accessibilityIdentifier("terminal.jumpSheet")
    }

    private func treeList(_ workspaces: [HerdrTreeWorkspace]) -> some View {
        List {
            ForEach(workspaces) { workspace in
                Section {
                    ForEach(workspace.tabs) { tab in
                        tabRows(tab)
                    }
                } header: {
                    // Herdr's labels are paths and ids; speak folder names
                    // ("Home", not a lone "~") like everywhere else (#54).
                    Text(
                        workspace.label.isEmpty
                            ? workspace.workspaceId
                            : HomeGrouping.projectName(of: workspace.label)
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // A tab renders one row per agent (the tappable targets); a tab with
    // no agents renders a single quiet, disabled row.
    @ViewBuilder
    private func tabRows(_ tab: HerdrTreeTab) -> some View {
        if tab.agents.isEmpty {
            HStack {
                Text(tab.label.isEmpty ? "Herdr pane" : tab.label)
                    .foregroundStyle(MochaTheme.textSecondary)
                Spacer()
                Text("Nothing attached")
                    .font(.caption)
                    .foregroundStyle(MochaTheme.textSecondary)
            }
        } else {
            ForEach(tab.agents) { agent in
                agentRow(agent)
            }
        }
    }

    private func agentRow(_ agent: AgentSummary) -> some View {
        let status = AgentStatusStyle.of(agent.status)
        let isCurrent = agent.id == currentPaneID
        // A switcher answers "where am I jumping?" — the second line is the
        // address, always: the abbreviated path, never a title standing in
        // for a place and never a bare folder name two rows could share.
        let location = agent.abbreviatedPath
        return Button {
            guard !isCurrent else {
                dismiss()
                return
            }
            onSelect(agent)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(MochaTheme.textPrimary)
                    Text(location)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MochaTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Text("Current")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MochaTheme.accent)
                } else {
                    Text(status.label)
                        .font(.caption)
                        .foregroundStyle(status.color)
                }
            }
        }
        .accessibilityLabel(
            "\(agent.displayName), \(status.label)\(isCurrent ? ", current session" : "")"
        )
        .accessibilityIdentifier("jump.agent.\(agent.id)")
    }
}
