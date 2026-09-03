import SwiftUI

// The sheet once the host has answered: which agent, and where it starts —
// a folder you pick, or a worktree made first (#75). Create stays disabled
// until the second question has an answer.
struct NewAgentForm: View {
    @Bindable var draft: NewAgentDraft
    let catalog: ProjectCatalog
    let computerCount: Int
    let computerName: String
    let startingIn: (hostId: String, path: String)?
    let sourceControl: HostSourceControlClient?
    // Remembered across sheets, so the kind you launched last leads.
    @Binding var rememberedKind: String
    let onChangeComputer: () -> Void

    var body: some View {
        let sections = ProjectPicker.sections(for: catalog, query: draft.query)
        List {
            if computerCount > 1 {
                // The answer to the first question stays visible and is
                // one tap to change.
                Section {
                    Button(action: onChangeComputer) {
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

            agentSection

            lockedFolderSection

            whereModeSection

            if draft.whereMode == .worktree, !draft.whereLocked {
                WorktreeForm(draft: draft, catalog: catalog, sourceControl: sourceControl)
            }

            folderSections(sections)

            // Last, not first (#54): Recent is the common path; the custom
            // field led the sheet visually while serving the rare case.
            if draft.whereMode == .folder, !draft.whereLocked {
                customPathSection
            }
        }
        .scrollContentBackground(.hidden)
        // Keep the search field in the navigation bar drawer; left to the
        // platform it anchors to the bottom of the sheet and floats over the
        // list content.
        .searchable(
            text: $draft.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Find a folder"
        )
        // iOS 26 still floats the field over the sheet's bottom; without
        // this inset it covers the last rows at rest (#54).
        .contentMargins(.bottom, 76, for: .scrollContent)
        .accessibilityIdentifier("newAgent.folders")
    }

    @ViewBuilder
    private var lockedFolderSection: some View {
        if draft.whereLocked, let startingIn {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(TaviTheme.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(HomeGrouping.projectName(of: startingIn.path))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(TaviTheme.textPrimary)
                        Text(startingIn.path)
                            .font(.caption2)
                            .foregroundStyle(TaviTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 8)
                    Button("Change") { draft.whereLocked = false }
                        .font(.subheadline)
                        .accessibilityIdentifier("newAgent.whereChange")
                }
                .accessibilityIdentifier("newAgent.whereLocked")
            } header: {
                Text("Where")
            }
            .listRowBackground(TaviTheme.card)
        }
    }

    // Where (#75): an existing folder, or a worktree made first.
    // Only offered when the host reported a repository to make it in.
    @ViewBuilder
    private var whereModeSection: some View {
        if !draft.repos.isEmpty, !draft.whereLocked {
            Section {
                Picker("Where", selection: $draft.whereMode) {
                    ForEach(NewAgentDraft.WhereMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .accessibilityIdentifier("newAgent.whereMode")
            } header: {
                Text("Where")
            }
            .listRowBackground(TaviTheme.card)
        }
    }

    @ViewBuilder
    private func folderSections(_ sections: ProjectPicker.Sections) -> some View {
        if draft.whereMode == .folder, !draft.whereLocked, !sections.recent.isEmpty {
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

        if draft.whereMode == .folder, !draft.whereLocked, !sections.projects.isEmpty {
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

        if draft.whereMode == .folder, !draft.whereLocked, sections.isEmpty {
            Section {
                Text(emptyMessage)
                    .font(.footnote)
                    .foregroundStyle(TaviTheme.textSecondary)
                    .accessibilityIdentifier("newAgent.empty")
            }
            .listRowBackground(TaviTheme.card)
        }
    }

    private var agentSection: some View {
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
                            draft.agentKind = kind.kind
                            rememberedKind = kind.kind
                        } label: {
                            if draft.agentKind == kind.kind {
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
                    Text(draft.agentKind.map { ProjectPicker.label(for: $0, in: catalog) } ?? "None available")
                        .foregroundStyle(draft.agentKind == nil ? TaviTheme.statusBlocked : TaviTheme.textSecondary)
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
            if let failure = draft.failure {
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
    }

    private var customPathSection: some View {
        Section {
            TextField("/Users/you/Projects/thing", text: $draft.customPath)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.footnote.monospaced())
                .accessibilityIdentifier("newAgent.customPath")
            Button("Use this folder") {
                select(draft.customPath.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .disabled(draft.customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("newAgent.useCustomPath")
        } header: {
            Text("Another folder")
        } footer: {
            if let selectedPath = draft.selectedPath, let agentKind = draft.agentKind {
                Text("Starting \(ProjectPicker.label(for: agentKind, in: catalog)) in \(selectedPath)")
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

    private var emptyMessage: String {
        if !draft.query.isEmpty {
            return "No folder matches “\(draft.query)”."
        }
        if catalog.roots.isEmpty {
            return "No project folders are configured on \(computerName), so every folder needs confirming. Set TAVI_ROOTS on the host, or type a full path below."
        }
        return "No project folders yet. Type a full path below to start somewhere specific."
    }

    private func select(_ path: String) {
        draft.selectedPath = path
        draft.failure = nil
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
                if draft.selectedPath == path {
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
        .accessibilityAddTraits(draft.selectedPath == path ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("newAgent.folder.\(path)")
    }
}
