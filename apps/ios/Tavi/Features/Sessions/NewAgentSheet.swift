import SwiftUI

// Start an agent in a folder you picked, never in the host's home directory
// (#24). The sheet asks two questions — which agent, and where — and the
// second one has no default: Create stays disabled until a folder is chosen.
// With more than one computer paired it asks a question before those:
// which computer (#50) — folders and agent kinds belong to one machine.
// The host decides whether a location is ordinary or needs a second look, so
// a folder outside its project roots comes back as a confirmation prompt
// rather than an error.
struct NewAgentSheet: View {
    let computers: [HostFleet.Entry]
    // Called after the sheet has asked to dismiss: the home opens the new
    // pane's terminal (#67) so you land in what you just created.
    let onCreated: (AgentTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    // The computer the agent will start on; chosen up front when there is
    // a choice, implied when there is one computer.
    @State private var chosenHostId: String?
    // Remembered across sheets: the kind you launched last is what you most
    // likely want next. Validated against the host's installed list on load.
    @AppStorage("tavi.newAgent.kind") private var rememberedKind = "claude"
    @State private var agentKind: String?
    @State private var selectedPath: String?
    @State private var query = ""
    @State private var customPath = ""
    @State private var inFlight = false
    @State private var failure: String?
    @State private var pendingOutsideRoots: String?

    private enum Phase: Equatable {
        case chooseComputer
        case loading
        case catalog(ProjectCatalog)
        case failed(String)
    }

    init(computers: [HostFleet.Entry], onCreated: @escaping (AgentTarget) -> Void) {
        self.computers = computers
        self.onCreated = onCreated
        _chosenHostId = State(initialValue: computers.count == 1 ? computers[0].id : nil)
        _phase = State(initialValue: computers.count == 1 ? .loading : .chooseComputer)
    }

    private var chosen: HostFleet.Entry? {
        computers.first { $0.id == chosenHostId }
    }

    private var directory: AgentDirectory? { chosen?.directory }

    // "your Mac" only when we do not know better: the name the computer
    // gave when pairing is what the person recognizes.
    private var computerName: String { chosen?.host.displayName ?? "your computer" }

    var body: some View {
        NavigationStack {
            content
                .background(TaviTheme.canvas.ignoresSafeArea())
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
                            guard !inFlight, selectedPath != nil, agentKind != nil, directory != nil else { return }
                            inFlight = true
                            Task { await create(allowOutsideRoots: false) }
                        }
                        .disabled(selectedPath == nil || agentKind == nil || inFlight || directory == nil)
                        .accessibilityIdentifier("newAgent.create")
                    }
                }
        }
        .task { await load() }
        // A computer removed while this sheet is open (Settings, or a
        // revocation) must not leave its folders on screen: back to the
        // question, or straight on if one computer remains.
        .onChange(of: computers.map(\.id)) { _, ids in
            guard let chosenHostId, !ids.contains(chosenHostId) else { return }
            self.chosenHostId = ids.count == 1 ? ids[0] : nil
            selectedPath = nil
            failure = nil
            Task { await load() }
        }
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
            Text("\(path) is not inside the project folders configured on \(computerName). The agent will be able to read and change files there.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .chooseComputer:
            computerList

        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Reading the projects on \(computerName)…")
                    .font(.callout)
                    .foregroundStyle(TaviTheme.textSecondary)
                chooseAnotherComputerButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("newAgent.loading")

        case let .failed(message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(TaviTheme.statusBlocked)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(TaviTheme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("newAgent.retry")
                // A sleeping computer must not be a dead end (#50).
                chooseAnotherComputerButton
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("newAgent.failed")

        case let .catalog(catalog):
            folderList(catalog)
        }
    }

    @ViewBuilder
    private var chooseAnotherComputerButton: some View {
        if computers.count > 1 {
            Button("Choose another computer") {
                phase = .chooseComputer
                selectedPath = nil
                failure = nil
            }
            .font(.footnote)
            .accessibilityIdentifier("newAgent.chooseAnotherComputer")
        }
    }

    // The first question when several computers are paired (#50): which
    // one. Health is on every row so a sleeping machine is a known quantity
    // before its folders fail to load.
    private var computerList: some View {
        List {
            Section {
                ForEach(computers) { entry in
                    Button {
                        chosenHostId = entry.id
                        Task { await load() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(TaviTheme.textSecondary)
                            Text(entry.host.displayName)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(TaviTheme.textPrimary)
                            Spacer(minLength: 8)
                            HostHealthLabel(
                                health: entry.directory.health,
                                latencyMilliseconds: entry.directory.latencyMilliseconds
                            )
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(TaviTheme.textSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("newAgent.computer.\(entry.id)")
                }
            } header: {
                Text("Which computer?")
            }
            .listRowBackground(TaviTheme.card)
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("newAgent.computers")
    }

    private func folderList(_ catalog: ProjectCatalog) -> some View {
        let sections = ProjectPicker.sections(for: catalog, query: query)
        return List {
            if computers.count > 1 {
                // The answer to the first question stays visible and is
                // one tap to change.
                Section {
                    Button {
                        phase = .chooseComputer
                        selectedPath = nil
                        failure = nil
                    } label: {
                        HStack {
                            Text("Computer")
                                .foregroundStyle(TaviTheme.textPrimary)
                            Spacer()
                            Text(computerName)
                                .foregroundStyle(TaviTheme.textSecondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(TaviTheme.textSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("newAgent.changeComputer")
                }
                .listRowBackground(TaviTheme.card)
            }

            Section {
                // One row, not one per kind: herdr can launch twenty-odd
                // agents, and listing them inline pushed the folders — the
                // actual decision — off the screen. Kinds not on this Mac
                // stay visible but disabled, so "why isn't X here?" has an
                // answer without cluttering the sheet.
                Menu {
                    Section("Installed") {
                        ForEach(catalog.agents.filter(\.installed)) { kind in
                            Button {
                                agentKind = kind.kind
                                rememberedKind = kind.kind
                            } label: {
                                if agentKind == kind.kind {
                                    Label(kind.label, systemImage: "checkmark")
                                } else {
                                    Text(kind.label)
                                }
                            }
                            .accessibilityIdentifier("newAgent.agentKind.\(kind.kind)")
                        }
                    }
                    let missing = catalog.agents.filter { !$0.installed }
                    if !missing.isEmpty {
                        Section("Not installed on \(computerName)") {
                            ForEach(missing) { kind in
                                Button(kind.label) {}.disabled(true)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Agent")
                            .foregroundStyle(TaviTheme.textPrimary)
                        Spacer()
                        Text(agentKind.map { label(for: $0, in: catalog) } ?? "None available")
                            .foregroundStyle(agentKind == nil ? TaviTheme.statusBlocked : TaviTheme.textSecondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(TaviTheme.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("newAgent.agentKind")
            } footer: {
                // A refusal must land where the user is looking; the
                // custom-path section's footer can be screens away.
                if let failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(TaviTheme.statusBlocked)
                        .accessibilityIdentifier("newAgent.error")
                } else if !catalog.agents.contains(where: \.installed) {
                    Text("No supported agent is installed on \(computerName). Install one (for example Claude Code or Codex) and reopen this sheet.")
                        .font(.footnote)
                        .foregroundStyle(TaviTheme.statusBlocked)
                        .accessibilityIdentifier("newAgent.noAgents")
                }
            }
            .listRowBackground(TaviTheme.card)

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
                .listRowBackground(TaviTheme.card)
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
                .listRowBackground(TaviTheme.card)
            }

            if sections.isEmpty {
                Section {
                    Text(emptyMessage(for: catalog))
                        .font(.footnote)
                        .foregroundStyle(TaviTheme.textSecondary)
                        .accessibilityIdentifier("newAgent.empty")
                }
                .listRowBackground(TaviTheme.card)
            }

            // Last, not first (#54): Recent is the common path; the custom
            // field led the sheet visually while serving the rare case.
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
                if let selectedPath, let agentKind {
                    Text("Starting \(label(for: agentKind, in: catalog)) in \(selectedPath)")
                        .font(.footnote)
                        .foregroundStyle(TaviTheme.textSecondary)
                } else {
                    Text("Pick the folder this agent should work in.")
                        .font(.footnote)
                        .foregroundStyle(TaviTheme.textSecondary)
                }
            }
            .listRowBackground(TaviTheme.card)
        }
        .scrollContentBackground(.hidden)
        // Keep the search field in the navigation bar drawer; left to the
        // platform it anchors to the bottom of the sheet and floats over the
        // list content.
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Find a folder"
        )
        // iOS 26 still floats the field over the sheet's bottom; without
        // this inset it covers the last rows at rest (#54).
        .contentMargins(.bottom, 76, for: .scrollContent)
        .accessibilityIdentifier("newAgent.folders")
    }

    private func label(for kind: String, in catalog: ProjectCatalog) -> String {
        catalog.agents.first { $0.kind == kind }?.label ?? kind
    }

    private func emptyMessage(for catalog: ProjectCatalog) -> String {
        if !query.isEmpty {
            return "No folder matches “\(query)”."
        }
        if catalog.roots.isEmpty {
            return "No project folders are configured on \(computerName), so every folder needs confirming. Set TAVI_ROOTS on the host, or type a full path below."
        }
        return "No project folders yet. Type a full path below to start somewhere specific."
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
                    .foregroundStyle(TaviTheme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(TaviTheme.textPrimary)
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(TaviTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    // Words in the row, not warning glyphs down the list:
                    // the alert only comes when the user actually picks it.
                    if needsConfirmation {
                        Text("Outside your project folders")
                            .font(.caption2)
                            .foregroundStyle(TaviTheme.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                // A quiet dot says "an agent is already running here" —
                // the blue link-styled word read as a tappable control.
                if badge != nil {
                    Circle()
                        .fill(TaviTheme.statusWorking)
                        .frame(width: 6, height: 6)
                }
                if selectedPath == path {
                    // Selection, not the "Done" status color.
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(TaviTheme.accent)
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
        guard let directory else {
            phase = .chooseComputer
            return
        }
        phase = .loading
        switch await directory.fetchProjects() {
        case let .catalog(catalog):
            agentKind = ProjectPicker.defaultAgentKind(in: catalog.agents, preferring: rememberedKind)
            phase = .catalog(catalog)
        case let .failure(message): phase = .failed(message)
        }
    }

    private func select(_ path: String) {
        selectedPath = path
        failure = nil
    }

    private func create(allowOutsideRoots: Bool, path: String? = nil) async {
        guard let cwd = path ?? selectedPath, let agentKind, let directory else {
            inFlight = false
            return
        }
        failure = nil
        inFlight = true
        defer { inFlight = false }

        switch await directory.createTab(agent: agentKind, cwd: cwd, allowOutsideRoots: allowOutsideRoots) {
        case let .created(paneId, _):
            // The row arrives on the live snapshot feed like any other; the
            // terminal opens right away on the pane the host named.
            dismiss()
            onCreated(AgentTarget(hostId: directory.hostId, paneId: paneId))
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
