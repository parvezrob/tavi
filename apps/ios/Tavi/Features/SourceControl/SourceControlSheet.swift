import SwiftUI

// Source Control for one worktree (#77; PRD §7.12, approved canvas "3 ·
// Source Control"). Three tabs, one job and one amber action each. This
// part ships Changes; Pull request and Commits say what they will be
// until #73 parts 4–5 land. The header carries what Orca's phone lacks:
// the branch against its base, and the agent's status.
struct SourceControlSheet: View {
    let worktree: HomeWorktree
    let repoName: String
    let client: HostSourceControlClient?
    let filesClient: HostFilesClient?
    let computerName: String?

    enum Tab: String, CaseIterable, Identifiable {
        case changes = "Changes"
        case pullRequest = "Pull request"
        case commits = "Commits"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .changes
    @State private var status: Loadable<WorktreeStatus> = .loading
    @State private var message = ""
    @State private var busy: Set<String> = []
    @State private var committing = false
    @State private var writing = false
    @State private var notice: String?
    @State private var openFile: FileTarget?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Picker("Source Control", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityIdentifier("sourceControl.tabs")

                switch tab {
                case .changes: changesTab
                case .pullRequest: placeholder("Pull request", "Creating and linking a pull request from here arrives with the next part of #73.")
                case .commits: placeholder("Commits", "The branch's commits, Push, and Pull main in arrive with the next part of #73.")
                }
            }
            .background(TaviTheme.canvas)
            .navigationTitle(worktree.info.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(item: $openFile) { target in
                FileViewerView(target: target, client: filesClient)
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        // Status keeps up while the sheet is open — the thing Orca's phone
        // does not do — on the same cadence as the home's repo poll.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, busy.isEmpty, !committing else { continue }
                await load(quietly: true)
            }
        }
        .accessibilityIdentifier("sourceControl.sheet")
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text([repoName, computerName].compactMap { $0 }.joined(separator: " · ") + syncSuffix)
                .font(.footnote)
                .foregroundStyle(TaviTheme.textSecondary)
                .lineLimit(1)
            if let agent = worktree.active.first ?? worktree.recent.first ?? worktree.needsYou.first {
                HStack(spacing: 8) {
                    Circle()
                        .fill(AgentStatusStyle.of(agent.status).color)
                        .frame(width: 6, height: 6)
                    Text("\(agent.displayName) · \(AgentStatusStyle.of(agent.status).label)")
                        .font(.footnote)
                        .foregroundStyle(TaviTheme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var syncSuffix: String {
        guard case let .loaded(status) = status, let base = status.base else { return "" }
        var parts: [String] = []
        if status.ahead > 0 { parts.append("↑\(status.ahead)") }
        if status.behind > 0 { parts.append("↓\(status.behind)") }
        return parts.isEmpty ? " · up to date with \(base)" : " · \(parts.joined(separator: " ")) vs \(base)"
    }

    // MARK: - Changes

    @ViewBuilder
    private var changesTab: some View {
        switch status {
        case .loading:
            loadingRow("Reading changes on \(computerName ?? "the computer")…")
        case let .failed(reason):
            messageCard(reason, identifier: "sourceControl.failed")
        case let .loaded(status):
            VStack(spacing: 0) {
                if status.files.isEmpty {
                    messageCard("Nothing uncommitted on \(worktree.info.title).", identifier: "sourceControl.empty")
                } else {
                    List {
                        Section {
                            ForEach(status.files) { file in
                                changedRow(file)
                                    .listRowBackground(TaviTheme.card)
                            }
                        } header: {
                            // The home's section register (SectionHeader):
                            // small caps, wide tracking — not the List's
                            // large default.
                            HStack(alignment: .firstTextBaseline) {
                                Text(status.files.count == 1 ? "1 changed" : "\(status.files.count) changed")
                                    .font(.caption.weight(.semibold))
                                    .kerning(1.1)
                                    .textCase(.uppercase)
                                    .foregroundStyle(TaviTheme.textSecondary)
                                Spacer()
                                Button(status.staged == status.files.count ? "Unstage all" : "Stage all") {
                                    Task { await stageAll(status) }
                                }
                                .font(.footnote)
                                .textCase(nil)
                                .foregroundStyle(TaviTheme.textSecondary)
                                .accessibilityIdentifier("sourceControl.stageAll")
                            }
                        } footer: {
                            if status.truncated { Text("Showing the first 500 changed files.") }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
                commitBox(status)
            }
        }
    }

    private func changedRow(_ file: ChangedFile) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { await toggle(file) }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(file.staged ? TaviTheme.textPrimary : Color.clear)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(file.staged ? Color.clear : TaviTheme.textSecondary.opacity(0.5), lineWidth: 1.5)
                    if file.staged {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(TaviTheme.accentInk)
                    }
                }
                .frame(width: 22, height: 22)
                .opacity(busy.contains(file.path) ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(busy.contains(file.path))
            .accessibilityLabel(file.staged ? "Staged" : "Not staged")
            .accessibilityIdentifier("sourceControl.stage.\(file.path)")

            Button {
                openFile = FileTarget(cwd: worktree.info.path, path: file.path, line: nil, mode: file.secret ? .refusedSecret : .diff, title: file.name)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .font(.subheadline)
                            .foregroundStyle(TaviTheme.textPrimary)
                            .lineLimit(1)
                        Text(file.directory.isEmpty ? file.stateLabel : "\(file.directory) · \(file.stateLabel)")
                            .font(.footnote)
                            .foregroundStyle(TaviTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 8)
                    if file.secret {
                        Text("Not shown")
                            .font(.footnote)
                            .foregroundStyle(TaviTheme.textSecondary)
                    } else if let additions = file.additions, let deletions = file.deletions {
                        HStack(spacing: 6) {
                            Text("+\(additions)").foregroundStyle(TaviTheme.statusDone)
                            Text("−\(deletions)").foregroundStyle(TaviTheme.diffRemoved)
                        }
                        .font(.footnote)
                        .monospacedDigit()
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(TaviTheme.textSecondary.opacity(0.6))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sourceControl.file.\(file.path)")
        }
    }

    // Pinned under the list: the message, one text link to have Claude
    // write it, and the one amber action. Disabled with the reason on it
    // while nothing is staged.
    private func commitBox(_ status: WorktreeStatus) -> some View {
        VStack(spacing: 12) {
            TextField("Commit message", text: $message, axis: .vertical)
                .lineLimit(1...4)
                .font(.body)
                .padding(12)
                .background(TaviTheme.card, in: RoundedRectangle(cornerRadius: TaviTheme.wellRadius, style: .continuous))
                .accessibilityIdentifier("sourceControl.message")
            HStack {
                Button(writing ? "Writing…" : "Let Claude write it") {
                    Task { await writeMessage() }
                }
                .font(.footnote)
                .foregroundStyle(TaviTheme.textSecondary)
                .disabled(writing || status.staged == 0)
                .accessibilityIdentifier("sourceControl.writeMessage")
                Spacer()
                Button(committing ? "Committing…" : commitLabel(status)) {
                    Task { await commit() }
                }
                .buttonStyle(.taviProminent)
                .disabled(committing || status.staged == 0 || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("sourceControl.commit")
            }
            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(TaviTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("sourceControl.notice")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(TaviTheme.canvas)
        .overlay(alignment: .top) { Divider().overlay(TaviTheme.hairline) }
    }

    private func commitLabel(_ status: WorktreeStatus) -> String {
        switch status.staged {
        case 0: "Nothing staged"
        case 1: "Commit 1 file"
        default: "Commit \(status.staged) files"
        }
    }

    // MARK: - Actions

    private func load(quietly: Bool = false) async {
        guard let client else {
            status = .failed("Connect a computer first.")
            return
        }
        switch await client.status(path: worktree.info.path) {
        case let .value(fresh):
            if case let .loaded(current) = status, current == fresh { return }
            status = .loaded(fresh)
        case let .refused(_, reason): if !quietly { status = .failed(reason) }
        case let .failure(reason): if !quietly { status = .failed(reason) }
        }
    }

    private func toggle(_ file: ChangedFile) async {
        guard let client else { return }
        busy.insert(file.path)
        defer { busy.remove(file.path) }
        let outcome = file.staged
            ? await client.unstage(path: worktree.info.path, files: [file.path])
            : await client.stage(path: worktree.info.path, files: [file.path])
        report(outcome)
        await load()
    }

    private func stageAll(_ status: WorktreeStatus) async {
        guard let client else { return }
        busy.insert("*")
        defer { busy.remove("*") }
        let outcome = status.staged == status.files.count
            ? await client.unstage(path: worktree.info.path, files: status.files.map(\.path))
            : await client.stageAll(path: worktree.info.path)
        report(outcome)
        await load()
    }

    private func writeMessage() async {
        guard let client else { return }
        writing = true
        defer { writing = false }
        switch await client.writeMessage(path: worktree.info.path) {
        case let .value(written):
            message = written.message
            notice = nil
        case let .refused(_, reason), let .failure(reason):
            notice = reason
        }
    }

    private func commit() async {
        guard let client else { return }
        committing = true
        defer { committing = false }
        switch await client.commit(path: worktree.info.path, message: message) {
        case let .value(receipt):
            message = ""
            notice = "Committed \(receipt.commit.files == 1 ? "1 file" : "\(receipt.commit.files) files"): \(receipt.commit.summary)"
        case let .refused(_, reason), let .failure(reason):
            notice = reason
        }
        await load()
    }

    private func report<Value>(_ outcome: HostSourceControlClient.Outcome<Value>) {
        switch outcome {
        case .value: notice = nil
        case let .refused(_, reason), let .failure(reason): notice = reason
        }
    }

    // MARK: - Shared

    private func placeholder(_ title: String, _ text: String) -> some View {
        messageCard(text, identifier: "sourceControl.placeholder.\(title)")
    }

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
}
