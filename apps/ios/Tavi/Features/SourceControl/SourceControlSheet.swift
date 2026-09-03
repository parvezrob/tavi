import SwiftUI

// Source Control for one worktree (#77; PRD §7.12, approved canvas "3 ·
// Source Control"). Three tabs, one job and one amber action each. This
// file draws Changes and the chrome around all three; the draft beside it
// holds what the sheet knows and does the asking, and SourceControlTabs
// draws the two reading tabs. The header carries what Orca's phone lacks:
// the branch against its base, and the agent's status.
struct SourceControlSheet: View {
    let worktree: HomeWorktree
    let repoName: String
    let filesClient: HostFilesClient?
    let computerName: String?
    // Remove (#81): the home refreshes and this sheet closes.
    var onRemoved: ((RemovalReceipt) -> Void)? = nil
    // "Start an agent here" (owner ask, 2026-09-02): the New Agent sheet
    // opens on this worktree's folder once this sheet has closed.
    var onStartAgent: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    // The client and the folder never change while the sheet is open, so
    // the draft takes them once here rather than at every call.
    @State private var draft: SourceControlDraft
    // Remove needs the client the draft was built with; it is the one
    // route this sheet still calls without going through the draft.
    private let client: HostSourceControlClient?

    init(
        worktree: HomeWorktree,
        repoName: String,
        client: HostSourceControlClient?,
        filesClient: HostFilesClient?,
        computerName: String?,
        onRemoved: ((RemovalReceipt) -> Void)? = nil,
        onStartAgent: (() -> Void)? = nil
    ) {
        self.worktree = worktree
        self.repoName = repoName
        self.client = client
        self.filesClient = filesClient
        self.computerName = computerName
        self.onRemoved = onRemoved
        self.onStartAgent = onStartAgent
        _draft = State(initialValue: SourceControlDraft(client: client, path: worktree.info.path))
    }

    var body: some View {
        @Bindable var draft = draft
        NavigationStack {
            VStack(spacing: 0) {
                SourceControlHeader(repoName: repoName, computerName: computerName, worktree: worktree, draft: draft)
                Picker("Source Control", selection: $draft.tab) {
                    ForEach(SourceControlDraft.Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, TaviTheme.Spacing.screen)
                .padding(.vertical, 10)
                .accessibilityIdentifier("sourceControl.tabs")

                switch draft.tab {
                case .changes: changesTab
                case .pullRequest: pullRequestTab
                case .commits: commitsTab
                }
            }
            .background(TaviTheme.canvas)
            .navigationTitle(worktree.info.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                // Remove lives behind ··· (the canvas): never a button a
                // thumb finds by accident. Starting an agent in the
                // worktree lives beside it.
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if let onStartAgent {
                            Button("Start an agent here…", systemImage: "plus") {
                                dismiss()
                                onStartAgent()
                            }
                            .accessibilityIdentifier("sourceControl.startAgent")
                        }
                        if !worktree.info.isMain {
                            Button("Remove worktree…", role: .destructive) { draft.removing = true }
                                .accessibilityIdentifier("sourceControl.remove")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .accessibilityLabel("More")
                    }
                    .accessibilityIdentifier("sourceControl.more")
                }
            }
            // One presentation transition at a time: the removal sheet
            // closes itself after the receipt, and only then does this one
            // go and the home hear about it.
            .sheet(isPresented: $draft.removing, onDismiss: {
                guard let receipt = draft.removedReceipt else { return }
                dismiss()
                onRemoved?(receipt)
            }) {
                RemoveWorktreeSheet(worktree: worktree, client: client, computerName: computerName) { receipt in
                    draft.removedReceipt = receipt
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(TaviTheme.canvas)
            }
            .navigationDestination(item: $draft.openFile) { target in
                FileViewerView(target: target, client: filesClient)
            }
        }
        .preferredColorScheme(.dark)
        .task { await draft.load() }
        // Status keeps up while the sheet is open — the thing Orca's phone
        // does not do — on the same cadence as the home's repo poll.
        .task {
            // 5 s while answers come; 15 s after a failure, so a bad link
            // is not asked three times as often as a good one (#86).
            var interval: Duration = .seconds(5)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, draft.busy.isEmpty, !draft.committing, !draft.pushing, !draft.pulling, !draft.creatingPullRequest, !draft.linking, !draft.removing, draft.removedReceipt == nil else { continue }
                await draft.load(quietly: true)
                if draft.tab == .commits { await draft.loadLog(quietly: true) }
                if draft.tab == .pullRequest { await draft.loadPullRequest(quietly: true) }
                if case .failed = draft.status { interval = .seconds(15) } else { interval = .seconds(5) }
            }
        }
        .onChange(of: draft.tab) { _, selected in draft.select(selected) }
        .onDisappear { draft.stopLoading() }
        .alert("Link a pull request", isPresented: $draft.askingForLink) {
            TextField("Number or GitHub link", text: $draft.linkReference)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("sourceControl.pr.linkField")
            Button("Link") { draft.linkPullRequest() }
                .disabled(draft.linkReference.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { draft.linkReference = "" }
        } message: {
            Text("The pull request on GitHub that this branch belongs to.")
        }
        // No identifier on the root: it would overwrite every child's.
    }

    // MARK: - Changes

    @ViewBuilder
    private var changesTab: some View {
        switch draft.status {
        case .loading:
            LoadingRow("Reading changes on \(computerName ?? "the computer")…", font: .subheadline)
        case let .failed(reason):
            MessageCard(reason, identifier: "sourceControl.failed", font: .subheadline)
        case let .loaded(status):
            VStack(spacing: 0) {
                if status.files.isEmpty {
                    MessageCard("Nothing uncommitted on \(worktree.info.title).", identifier: "sourceControl.empty", font: .subheadline)
                } else {
                    List {
                        Section {
                            ForEach(status.files) { file in
                                changedRow(file)
                                    .listRowBackground(TaviTheme.card)
                            }
                        } header: {
                            // The home's section register, not the List's
                            // large default. "Stage all" stays on offer until
                            // every file is fully staged — a partly staged
                            // file still has something to stage.
                            SectionHeader(title: status.files.count == 1 ? "1 changed" : "\(status.files.count) changed") {
                                Button(status.isFullyStaged ? "Unstage all" : "Stage all") {
                                    draft.stageAll(status)
                                }
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

    // The checkbox tells the truth in three states (PRD §7.15): empty, a
    // check, and a dash for a file with some hunks staged and some not —
    // the full check it used to draw promised a commit of the whole file.
    private func changedRow(_ file: ChangedFile) -> some View {
        let partlyStaged = file.staged && file.unstaged
        return HStack(spacing: 12) {
            Button {
                draft.toggle(file)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(file.staged ? TaviTheme.textPrimary : Color.clear)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(file.staged ? Color.clear : TaviTheme.textSecondary.opacity(0.5), lineWidth: 1.5)
                    if file.staged {
                        Image(systemName: partlyStaged ? "minus" : "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(TaviTheme.accentInk)
                    }
                }
                .frame(width: 22, height: 22)
                .opacity(draft.busy.contains(file.path) ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(draft.busy.contains(file.path))
            .accessibilityLabel(partlyStaged ? "Partly staged" : file.staged ? "Staged" : "Not staged")
            .accessibilityHint(partlyStaged ? "Stages the rest of the file" : file.staged ? "Unstages" : "Stages")
            .accessibilityIdentifier("sourceControl.stage.\(file.path)")

            Button {
                draft.openFile = FileTarget(cwd: worktree.info.path, path: file.path, line: nil, mode: file.secret ? .refusedSecret : .diff, title: file.name)
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
        @Bindable var draft = draft
        return VStack(spacing: 12) {
            TextField("Commit message", text: $draft.message, axis: .vertical)
                .lineLimit(1...4)
                .font(.body)
                .padding(TaviTheme.Spacing.snug)
                .background(TaviTheme.card, in: RoundedRectangle(cornerRadius: TaviTheme.wellRadius, style: .continuous))
                .accessibilityIdentifier("sourceControl.message")
            HStack {
                Button(draft.writing ? "Writing…" : "Let Claude write it") {
                    draft.writeMessage()
                }
                .font(.footnote)
                .foregroundStyle(TaviTheme.textSecondary)
                .disabled(draft.writing || status.staged == 0)
                .accessibilityIdentifier("sourceControl.writeMessage")
                Spacer()
                Button(draft.committing ? "Committing…" : commitLabel(status)) {
                    draft.commit()
                }
                .buttonStyle(.taviProminent)
                .disabled(draft.committing || status.staged == 0 || draft.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("sourceControl.commit")
            }
            if let notice = draft.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(TaviTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("sourceControl.notice")
            }
        }
        .padding(.horizontal, TaviTheme.Spacing.screen)
        .padding(.top, TaviTheme.Spacing.snug)
        .padding(.bottom, TaviTheme.Spacing.snug)
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

    // MARK: - The reading tabs

    private var pullRequestTab: some View {
        PullRequestTab(draft: draft, computerName: computerName)
    }

    private var commitsTab: some View {
        CommitsTab(draft: draft, worktreeTitle: worktree.info.title, computerName: computerName)
    }
}
