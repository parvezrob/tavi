import SwiftUI

// Start an agent in a folder you picked, never in the host's home directory
// (#24). The sheet asks two questions — which agent, and where — and the
// second one has no default: Create stays disabled until a folder is chosen.
// The host decides whether a location is ordinary or needs a second look, so
// a folder outside its project roots comes back as a confirmation prompt
// rather than an error.
struct NewAgentSheet: View {
    let directory: AgentDirectory

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var agentKind = "claude"
    @State private var selectedPath: String?
    @State private var query = ""
    @State private var customPath = ""
    @State private var inFlight = false
    @State private var failure: String?
    @State private var pendingOutsideRoots: String?

    private enum Phase: Equatable {
        case loading
        case catalog(ProjectCatalog)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            content
                .background(MochaTheme.canvas.ignoresSafeArea())
                .navigationTitle("New Agent")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            // Disable before the task starts: two taps inside
                            // one frame would otherwise create two agents.
                            guard !inFlight, selectedPath != nil else { return }
                            inFlight = true
                            Task { await create(allowOutsideRoots: false) }
                        }
                        .disabled(selectedPath == nil || inFlight)
                        .accessibilityIdentifier("newAgent.create")
                    }
                }
        }
        .task { await load() }
        .alert(
            "Start outside your project folders?",
            isPresented: Binding(
                get: { pendingOutsideRoots != nil },
                set: { if !$0 { pendingOutsideRoots = nil } }
            ),
            presenting: pendingOutsideRoots
        ) { path in
            Button("Cancel", role: .cancel) { pendingOutsideRoots = nil }
                .accessibilityIdentifier("newAgent.outsideRoots.cancel")
            Button("Start here", role: .destructive) {
                pendingOutsideRoots = nil
                inFlight = true
                Task { await create(allowOutsideRoots: true, path: path) }
            }
            .accessibilityIdentifier("newAgent.outsideRoots.confirm")
        } message: { path in
            Text("\(path) is not inside the project folders configured on your Mac. The agent will be able to read and change files there.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Reading your projects…")
                    .font(.callout)
                    .foregroundStyle(MochaTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("newAgent.loading")

        case let .failed(message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(MochaTheme.statusBlocked)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(MochaTheme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("newAgent.retry")
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("newAgent.failed")

        case let .catalog(catalog):
            folderList(catalog)
        }
    }

    private func folderList(_ catalog: ProjectCatalog) -> some View {
        let sections = ProjectPicker.sections(for: catalog, query: query)
        return List {
            Section {
                Picker("Agent", selection: $agentKind) {
                    Text("Claude").tag("claude")
                    Text("Codex").tag("codex")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("newAgent.agentKind")
            }
            .listRowBackground(MochaTheme.card)

            if !sections.recent.isEmpty {
                Section("Recent") {
                    ForEach(sections.recent) { folder in
                        folderRow(
                            path: folder.path,
                            name: folder.name,
                            badge: folder.active ? "Running" : nil,
                            needsConfirmation: !folder.withinRoots
                        )
                    }
                }
                .listRowBackground(MochaTheme.card)
            }

            if !sections.projects.isEmpty {
                Section("Projects") {
                    ForEach(sections.projects) { workspace in
                        folderRow(
                            path: workspace.path,
                            name: workspace.name,
                            badge: nil,
                            icon: workspace.git ? "shippingbox" : "folder"
                        )
                    }
                }
                .listRowBackground(MochaTheme.card)
            }

            if sections.isEmpty {
                Section {
                    Text(emptyMessage(for: catalog))
                        .font(.footnote)
                        .foregroundStyle(MochaTheme.textSecondary)
                        .accessibilityIdentifier("newAgent.empty")
                }
                .listRowBackground(MochaTheme.card)
            }

            Section {
                TextField("/Users/you/Projects/thing", text: $customPath)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.footnote.monospaced())
                    .accessibilityIdentifier("newAgent.customPath")
                Button("Use this folder") {
                    select(customPath.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .disabled(customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("newAgent.useCustomPath")
            } header: {
                Text("Another folder")
            } footer: {
                if let failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(MochaTheme.statusBlocked)
                        .accessibilityIdentifier("newAgent.error")
                } else if let selectedPath {
                    Text("Starting \(agentKind) in \(selectedPath)")
                        .font(.footnote)
                        .foregroundStyle(MochaTheme.textSecondary)
                } else {
                    Text("Pick the folder this agent should work in.")
                        .font(.footnote)
                        .foregroundStyle(MochaTheme.textSecondary)
                }
            }
            .listRowBackground(MochaTheme.card)
        }
        .scrollContentBackground(.hidden)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a folder")
        .accessibilityIdentifier("newAgent.folders")
    }

    private func emptyMessage(for catalog: ProjectCatalog) -> String {
        if !query.isEmpty {
            return "No folder matches “\(query)”."
        }
        if catalog.roots.isEmpty {
            return "No project folders are configured on your Mac, so every folder here needs confirming. Set MOCHA_ROOTS on the host, or enter a full path below."
        }
        return "No project folders yet. Enter a full path below to start somewhere specific."
    }

    private func folderRow(
        path: String,
        name: String,
        badge: String?,
        icon: String = "folder",
        needsConfirmation: Bool = false
    ) -> some View {
        Button {
            select(path)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(MochaTheme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(MochaTheme.textPrimary)
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(MochaTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 8)
                if needsConfirmation {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(MochaTheme.statusBlocked)
                }
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MochaTheme.statusWorking)
                }
                if selectedPath == path {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(MochaTheme.statusDone)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Purpose and state, not the icons: whether an agent is already
        // running here, whether starting here will ask for confirmation,
        // and whether this is the folder Create will use.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(
            [path, badge.map { "\($0) here" }, needsConfirmation ? "Outside your project folders" : nil]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
        .accessibilityAddTraits(selectedPath == path ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("newAgent.folder.\(path)")
    }

    private func load() async {
        phase = .loading
        switch await directory.fetchProjects() {
        case let .catalog(catalog): phase = .catalog(catalog)
        case let .failure(message): phase = .failed(message)
        }
    }

    private func select(_ path: String) {
        selectedPath = path
        failure = nil
    }

    private func create(allowOutsideRoots: Bool, path: String? = nil) async {
        guard let cwd = path ?? selectedPath else {
            inFlight = false
            return
        }
        failure = nil
        inFlight = true
        defer { inFlight = false }

        switch await directory.createTab(agent: agentKind, cwd: cwd, allowOutsideRoots: allowOutsideRoots) {
        case .created:
            // The new agent arrives on the live snapshot feed like any other.
            dismiss()
        case .needsOutsideRootsConfirmation where allowOutsideRoots:
            // The host asked to confirm a location this call already
            // confirmed. Never re-raise the alert: that is a loop with no
            // exit but Cancel.
            failure = "The host would not start an agent in \(cwd) even after confirmation."
        case .needsOutsideRootsConfirmation:
            pendingOutsideRoots = cwd
        case let .failure(message):
            failure = message
        }
    }
}
