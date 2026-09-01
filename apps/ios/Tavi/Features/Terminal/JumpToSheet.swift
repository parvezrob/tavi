import SwiftUI

// One paired computer as the Jump-to sheet reads it (#50).
struct JumpSource: Identifiable {
    let hostId: String
    let name: String
    let directory: AgentDirectory

    var id: String { hostId }
}

// "Jump to" (screen T1): the Herdr workspace → tab hierarchy inside the
// focused terminal, for every paired computer (#50). Tabs with agents
// switch the terminal to that exact host + pane; agent-less tabs stay
// visible but inert — plain panes are not attachable yet, and pretending
// otherwise would fake a capability.
struct JumpToSheet: View {
    let sources: [JumpSource]
    let currentTarget: AgentTarget?
    let onSelect: (AgentSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    // One fetch per computer, each landing on its own; a slow host never
    // holds up the others. Cancelled with the sheet.
    @State private var fetches: [String: HerdrTreeFetch] = [:]
    @State private var fetchTasks: [Task<Void, Never>] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(sources) { source in
                    sourceSections(source)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(TaviTheme.canvas)
            .navigationTitle("Jump to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            // One task per computer rather than a group: each answer lands
            // as it arrives, and a slow host never holds up the others.
            fetchTasks = sources.map { source in
                Task {
                    let fetch = await source.directory.fetchTree()
                    guard !Task.isCancelled else { return }
                    fetches[source.hostId] = fetch
                }
            }
        }
        .onDisappear {
            for task in fetchTasks { task.cancel() }
            fetchTasks = []
        }
        .accessibilityIdentifier("terminal.jumpSheet")
    }

    // With several computers every section header names its computer, so
    // two "api" folders on two machines never read as one.
    @ViewBuilder
    private func sourceSections(_ source: JumpSource) -> some View {
        let prefix = sources.count > 1 ? "\(source.name) · " : ""
        switch fetches[source.hostId] {
        case nil:
            Section(prefix.isEmpty ? "" : source.name) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading \(source.name)…")
                        .foregroundStyle(TaviTheme.textSecondary)
                }
            }
        case let .failure(reason):
            // The same words the home uses for that computer; a raw HTTP
            // status is not an explanation a person can act on.
            Section(prefix.isEmpty ? "" : source.name) {
                Label {
                    Text(Self.failureText(reason, health: source.directory.health, name: source.name))
                        .font(.footnote)
                        .foregroundStyle(TaviTheme.textSecondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(TaviTheme.statusBlocked)
                }
                .accessibilityIdentifier("jump.failed.\(source.hostId)")
            }
        case let .tree(workspaces):
            if workspaces.isEmpty {
                Section(prefix.isEmpty ? "" : source.name) {
                    Text("Nothing running on \(source.name).")
                        .foregroundStyle(TaviTheme.textSecondary)
                }
            }
            ForEach(workspaces) { workspace in
                Section {
                    ForEach(workspace.tabs) { tab in
                        tabRows(tab)
                    }
                } header: {
                    // Herdr's labels are paths and ids; speak folder names
                    // ("Home", not a lone "~") like everywhere else (#54).
                    Text(
                        prefix + (workspace.label.isEmpty
                            ? workspace.workspaceId
                            : HomeGrouping.projectName(of: workspace.label))
                    )
                }
            }
        }
    }

    static func failureText(_ reason: String, health: HostHealth, name: String) -> String {
        switch health {
        case .revoked: "This iPhone is no longer paired with \(name)."
        case .offline: "\(name) isn't answering right now."
        case .stale, .connecting: "Reconnecting to \(name)…"
        case .live: reason.replacingOccurrences(of: " \\(HTTP \\d+\\)", with: "", options: .regularExpression)
        }
    }

    // A tab renders one row per agent (the tappable targets); a tab with
    // no agents renders a single quiet, disabled row.
    @ViewBuilder
    private func tabRows(_ tab: HerdrTreeTab) -> some View {
        if tab.agents.isEmpty {
            HStack {
                Text(tab.label.isEmpty ? "Herdr pane" : tab.label)
                    .foregroundStyle(TaviTheme.textSecondary)
                Spacer()
                Text("Nothing attached")
                    .font(.caption)
                    .foregroundStyle(TaviTheme.textSecondary)
            }
        } else {
            ForEach(tab.agents) { agent in
                agentRow(agent)
            }
        }
    }

    private func agentRow(_ agent: AgentSummary) -> some View {
        let status = AgentStatusStyle.of(agent.status)
        let isCurrent = agent.target == currentTarget
        // A switcher answers "where am I jumping?" — the second line always
        // ends in the address. Your name for the tab (#55) leads it when
        // one exists: "fix auth bug · ~/Projects/api".
        let location = agent.userTabName.map { "\($0) · \(agent.abbreviatedPath)" }
            ?? agent.abbreviatedPath
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
                        .foregroundStyle(TaviTheme.textPrimary)
                    Text(location)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TaviTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Text("Current")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(TaviTheme.accent)
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
