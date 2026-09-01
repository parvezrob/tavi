import SwiftUI

// "Files" for one agent (#25, #57, #61): what it changed, what it
// mentioned, and — as the fallback — what else is in its folder. Read-only
// by construction: the host has no write route, and this sheet has no
// button that would need one. The default view is *changed* because "what
// did it just touch" is the question at 11pm; the tree is the fallback.
struct FilesSheet: View {
    let agent: AgentSummary
    let client: HostFilesClient?
    let computerName: String?
    // The terminal's plain-text transcript when opened from a terminal;
    // nil from the home, where there is nothing to scan.
    let transcript: String?
    var initialTab: Tab = .changed

    enum Tab: String, CaseIterable, Identifiable {
        case changed = "Changed"
        case mentioned = "Mentioned"
        case browse = "Browse"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .changed
    @State private var changes: Loadable<ChangesResponse> = .loading
    @State private var mentioned: Loadable<[MentionedFile]> = .loading
    @State private var openFile: FileTarget?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Files", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityIdentifier("files.tabs")

                switch tab {
                case .changed: changedList
                case .mentioned: mentionedList
                case .browse: BrowseView(agent: agent, client: client, startPath: agent.cwd) { openFile = $0 }
                }
            }
            .background(TaviTheme.canvas)
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(item: $openFile) { target in
                FileViewerView(target: target, client: client)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            tab = initialTab
            await loadChanges()
            await loadMentioned()
        }
        .accessibilityIdentifier("files.sheet")
    }

    // MARK: - Changed (#25)

    @ViewBuilder
    private var changedList: some View {
        switch changes {
        case .loading:
            loadingRow("Reading changes on \(computerName ?? "the computer")…")
        case let .failed(message):
            messageCard(message, identifier: "files.changes.failed")
        case let .loaded(response):
            if response.files.isEmpty {
                messageCard(
                    "Nothing uncommitted in \(HomeGrouping.projectName(of: response.repository))" + (response.branch.map { " on \($0)." } ?? "."),
                    identifier: "files.changes.empty"
                )
            } else {
                List {
                    Section {
                        ForEach(response.files) { file in
                            Button {
                                openFile = FileTarget(cwd: response.repository, path: file.path, line: nil, mode: file.secret ? .refusedSecret : .diff, title: file.name)
                            } label: {
                                changedRow(file)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(TaviTheme.card)
                            .accessibilityIdentifier("files.changed.\(file.path)")
                        }
                    } header: {
                        Text(header(for: response))
                    } footer: {
                        if response.truncated {
                            Text("Showing the first 500 changed files.")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func header(for response: ChangesResponse) -> String {
        var parts = [HomeGrouping.projectName(of: response.repository)]
        if let branch = response.branch { parts.append(branch) }
        parts.append(response.files.count == 1 ? "1 file" : "\(response.files.count) files")
        return parts.joined(separator: " · ")
    }

    private func changedRow(_ file: ChangedFile) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(TaviTheme.textPrimary)
                    .lineLimit(1)
                if let from = file.from {
                    Text("\(from) → \(file.path)")
                        .font(.caption)
                        .foregroundStyle(TaviTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else if !file.directory.isEmpty {
                    Text(file.directory)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TaviTheme.textSecondary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            if file.secret {
                Text("Not shown")
                    .font(.caption)
                    .foregroundStyle(TaviTheme.textSecondary)
            } else if let additions = file.additions, let deletions = file.deletions {
                HStack(spacing: 6) {
                    Text("+\(additions)")
                        .foregroundStyle(TaviTheme.statusDone)
                    Text("−\(deletions)")
                        .foregroundStyle(TaviTheme.diffRemoved)
                }
                .font(.caption.weight(.medium))
                .monospacedDigit()
            }
            Text(file.stateLabel)
                .font(.caption)
                .foregroundStyle(TaviTheme.textSecondary)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(TaviTheme.textSecondary.opacity(0.6))
        }
        .contentShape(Rectangle())
    }

    private func loadChanges() async {
        guard let client else {
            changes = .failed("Connect a computer first.")
            return
        }
        switch await client.changes(cwd: agent.cwd) {
        case let .value(response): changes = .loaded(response)
        case let .refused(_, refusal): changes = .failed(refusal.error)
        case let .failure(message): changes = .failed(message)
        }
    }

    // MARK: - Mentioned (#61)

    struct MentionedFile: Identifiable, Equatable {
        let mention: MentionedPath
        // What the host said: a real file (with its kind), refused, or nothing.
        let stat: FileStatInfo?
        let refusal: String?
        var id: String { mention.display }
    }

    @ViewBuilder
    private var mentionedList: some View {
        switch mentioned {
        case .loading:
            loadingRow("Looking for files the agent mentioned…")
        case let .failed(message):
            messageCard(message, identifier: "files.mentioned.failed")
        case let .loaded(files):
            if files.isEmpty {
                messageCard(
                    transcript == nil
                        ? "Open the agent's terminal to see the files it mentions."
                        : "No file paths on this screen yet. Paths the agent prints — “I wrote the plan to docs/PLAN.md” — show up here.",
                    identifier: "files.mentioned.empty"
                )
            } else {
                List {
                    Section {
                        ForEach(files) { file in
                            mentionedRow(file)
                                .listRowBackground(TaviTheme.card)
                        }
                    } footer: {
                        Text("Paths the agent printed, newest first. Only files that exist are offered; anything outside your project folders is refused by name.")
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder
    private func mentionedRow(_ file: MentionedFile) -> some View {
        if let stat = file.stat {
            Button {
                openFile = FileTarget(
                    cwd: agent.cwd,
                    path: stat.path,
                    line: file.mention.line,
                    mode: stat.preview == .directory ? .directory : .content,
                    title: stat.name
                )
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: stat.preview == .directory ? "folder" : "doc.text")
                        .foregroundStyle(TaviTheme.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.mention.display)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(TaviTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text(stat.preview == .directory ? "Folder" : Self.sizeLabel(stat.size))
                            .font(.caption)
                            .foregroundStyle(TaviTheme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(TaviTheme.textSecondary.opacity(0.6))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("files.mentioned.\(file.mention.path)")
        } else {
            // Refused, and said so: hiding it would make the list lie about
            // what the agent talked about.
            HStack(spacing: 12) {
                Image(systemName: "lock")
                    .foregroundStyle(TaviTheme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.mention.display)
                        .font(.subheadline)
                        .foregroundStyle(TaviTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text(file.refusal ?? "Not shown.")
                        .font(.caption)
                        .foregroundStyle(TaviTheme.textSecondary)
                }
            }
            .accessibilityIdentifier("files.mentioned.refused.\(file.mention.path)")
        }
    }

    private func loadMentioned() async {
        guard let transcript else {
            mentioned = .loaded([])
            return
        }
        guard let client else {
            mentioned = .failed("Connect a computer first.")
            return
        }
        let candidates = MentionedPathScanner.scan(transcript)
        // One stat per candidate, concurrently; the host answers a miss
        // cheaply, so only real files (and named refusals) survive.
        let results: [(Int, MentionedFile?)] = await withTaskGroup(of: (Int, MentionedFile?).self) { group in
            for (index, mention) in candidates.enumerated() {
                group.addTask {
                    switch await client.stat(cwd: agent.cwd, path: mention.path) {
                    case let .value(stat):
                        return (index, MentionedFile(mention: mention, stat: stat, refusal: nil))
                    case let .refused(status, refusal):
                        // 403 = outside the roots or a secret: shown as refused. 404 = not a file: dropped.
                        return (index, status == 403 ? MentionedFile(mention: mention, stat: nil, refusal: refusal.error) : nil)
                    case .failure:
                        return (index, nil)
                    }
                }
            }
            var collected: [(Int, MentionedFile?)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        let files = results.sorted { $0.0 < $1.0 }.compactMap(\.1)
        mentioned = .loaded(files)
    }

    // MARK: - Shared

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text)
                .font(.callout)
                .foregroundStyle(TaviTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func messageCard(_ text: String, identifier: String) -> some View {
        VStack {
            Text(text)
                .font(.callout)
                .foregroundStyle(TaviTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(20)
                .frame(maxWidth: .infinity)
                .taviCard()
                .accessibilityIdentifier(identifier)
            Spacer()
        }
        .padding(16)
    }

    static func sizeLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

enum Loadable<Value> {
    case loading
    case loaded(Value)
    case failed(String)
}

// What the viewer opens: a file (content), one file's diff, a folder, or a
// refusal already known from the list.
struct FileTarget: Hashable, Identifiable {
    enum Mode: Hashable {
        case content
        case diff
        case directory
        case refusedSecret
    }

    let cwd: String
    let path: String
    let line: Int?
    let mode: Mode
    let title: String

    var id: String { "\(mode)|\(cwd)|\(path)|\(line ?? 0)" }
}

// The alphabetical fallback (#57): one folder at a time, gitignored entries
// dimmed and last, never hidden. Starts at the agent's own folder.
struct BrowseView: View {
    let agent: AgentSummary
    let client: HostFilesClient?
    let startPath: String
    let onOpen: (FileTarget) -> Void

    @State private var path: String
    @State private var listing: Loadable<DirectoryListing> = .loading

    init(agent: AgentSummary, client: HostFilesClient?, startPath: String, onOpen: @escaping (FileTarget) -> Void) {
        self.agent = agent
        self.client = client
        self.startPath = startPath
        self.onOpen = onOpen
        _path = State(initialValue: startPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if path != startPath {
                    Button {
                        path = (path as NSString).deletingLastPathComponent
                    } label: {
                        Label("Up", systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityIdentifier("files.browse.up")
                }
                Text(path.abbreviatingHomeDirectory)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(TaviTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
            switch listing {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(TaviTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .taviCard()
                    .padding(16)
                Spacer()
            case let .loaded(directory):
                List {
                    Section {
                        ForEach(directory.entries) { entry in
                            Button {
                                let full = (directory.path as NSString).appendingPathComponent(entry.name)
                                if entry.isDirectory {
                                    path = full
                                } else {
                                    onOpen(FileTarget(cwd: agent.cwd, path: full, line: nil, mode: entry.preview == .secret ? .refusedSecret : .content, title: entry.name))
                                }
                            } label: {
                                entryRow(entry)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(TaviTheme.card)
                            .accessibilityIdentifier("files.browse.\(entry.name)")
                        }
                    } footer: {
                        if directory.truncated {
                            Text("Showing the first 2 000 entries.")
                        } else if directory.entries.isEmpty {
                            Text("Empty folder.")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .task(id: path) { await load() }
    }

    private func entryRow(_ entry: DirectoryEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder" : glyph(for: entry.preview))
                .foregroundStyle(TaviTheme.textSecondary)
                .frame(width: 20)
            Text(entry.name)
                .font(.subheadline)
                .foregroundStyle(TaviTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if !entry.isDirectory {
                Text(FilesSheet.sizeLabel(entry.size))
                    .font(.caption)
                    .foregroundStyle(TaviTheme.textSecondary)
                    .monospacedDigit()
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(TaviTheme.textSecondary.opacity(0.6))
        }
        .opacity(entry.ignored ? 0.45 : 1)
        .contentShape(Rectangle())
        .accessibilityLabel(entry.name + (entry.ignored ? ", ignored by git" : ""))
    }

    private func glyph(for preview: FilePreviewKind) -> String {
        switch preview {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .secret: "lock"
        case .binary: "doc.zipper"
        default: "doc.text"
        }
    }

    private func load() async {
        guard let client else {
            listing = .failed("Connect a computer first.")
            return
        }
        listing = .loading
        switch await client.list(cwd: agent.cwd, path: path) {
        case let .value(directory): listing = .loaded(directory)
        case let .refused(_, refusal): listing = .failed(refusal.error)
        case let .failure(message): listing = .failed(message)
        }
    }
}
