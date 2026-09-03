// Over the 400-line line; split in #69.
// swiftlint:disable file_length

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
    // Remove (#81): the home refreshes and this sheet closes.
    var onRemoved: ((RemovalReceipt) -> Void)? = nil
    // "Start an agent here" (owner ask, 2026-09-02): the New Agent sheet
    // opens on this worktree's folder once this sheet has closed.
    var onStartAgent: (() -> Void)? = nil

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
    // Commits (#78): loaded when the tab is opened, refreshed on the same
    // cadence while it stays open.
    @State private var log: Loadable<WorktreeLog> = .loading
    @State private var pushing = false
    @State private var pulling = false
    @State private var commitsNotice: String?
    // Pull request (#79).
    @State private var pullRequest: Loadable<PullRequestStatus> = .loading
    @State private var creatingPullRequest = false
    @State private var linking = false
    @State private var askingForLink = false
    @State private var linkReference = ""
    @State private var pullRequestNotice: String?
    @State private var pullRequestTitle = ""
    @State private var removing = false
    @State private var removedReceipt: RemovalReceipt?
    @State private var tabLoad: Task<Void, Never>?
    @Environment(\.openURL) private var openURL

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
                            Button("Remove worktree…", role: .destructive) { removing = true }
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
            .sheet(isPresented: $removing, onDismiss: {
                guard let receipt = removedReceipt else { return }
                dismiss()
                onRemoved?(receipt)
            }) {
                RemoveWorktreeSheet(worktree: worktree, client: client, computerName: computerName) { receipt in
                    removedReceipt = receipt
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(TaviTheme.canvas)
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
            // 5 s while answers come; 15 s after a failure, so a bad link
            // is not asked three times as often as a good one (#86).
            var interval: Duration = .seconds(5)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, busy.isEmpty, !committing, !pushing, !pulling, !creatingPullRequest, !linking, !removing, removedReceipt == nil else { continue }
                await load(quietly: true)
                if tab == .commits { await loadLog(quietly: true) }
                if tab == .pullRequest { await loadPullRequest(quietly: true) }
                if case .failed = status { interval = .seconds(15) } else { interval = .seconds(5) }
            }
        }
        .onChange(of: tab) { _, selected in
            tabLoad?.cancel()
            tabLoad = Task {
                if selected == .commits { await loadLog() }
                if selected == .pullRequest { await loadPullRequest() }
            }
        }
        .onDisappear { tabLoad?.cancel() }
        .alert("Link a pull request", isPresented: $askingForLink) {
            TextField("Number or GitHub link", text: $linkReference)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("sourceControl.pr.linkField")
            Button("Link") { begin($linking) { await linkPullRequest() } }
                .disabled(linkReference.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { linkReference = "" }
        } message: {
            Text("The pull request on GitHub that this branch belongs to.")
        }
        // No identifier on the root: it would overwrite every child's.
    }

    // Every action flips its flag on the tap itself, before the Task, so
    // two taps in one frame cannot commit, push, or create twice (the
    // NewAgentSheet rule; #81 review).
    private func begin(_ flag: Binding<Bool>, _ action: @escaping () async -> Void) {
        guard !flag.wrappedValue else { return }
        flag.wrappedValue = true
        Task {
            await action()
            flag.wrappedValue = false
        }
    }

    private func beginBusy(_ key: String, _ action: @escaping () async -> Void) {
        guard !busy.contains(key) else { return }
        busy.insert(key)
        Task {
            await action()
            busy.remove(key)
        }
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
                                Button(Self.isFullyStaged(status) ? "Unstage all" : "Stage all") {
                                    beginBusy("*") { await stageAll(status) }
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

    // Every file fully staged — only then does the section offer to undo it.
    private static func isFullyStaged(_ status: WorktreeStatus) -> Bool {
        status.files.allSatisfy { $0.staged && !$0.unstaged }
    }

    // The checkbox tells the truth in three states (PRD §7.15): empty, a
    // check, and a dash for a file with some hunks staged and some not —
    // the full check it used to draw promised a commit of the whole file.
    private func changedRow(_ file: ChangedFile) -> some View {
        let partlyStaged = file.staged && file.unstaged
        return HStack(spacing: 12) {
            Button {
                beginBusy(file.path) { await toggle(file) }
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
                .opacity(busy.contains(file.path) ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(busy.contains(file.path))
            .accessibilityLabel(partlyStaged ? "Partly staged" : file.staged ? "Staged" : "Not staged")
            .accessibilityHint(partlyStaged ? "Stages the rest of the file" : file.staged ? "Unstages" : "Stages")
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
                    begin($writing) { await writeMessage() }
                }
                .font(.footnote)
                .foregroundStyle(TaviTheme.textSecondary)
                .disabled(writing || status.staged == 0)
                .accessibilityIdentifier("sourceControl.writeMessage")
                Spacer()
                Button(committing ? "Committing…" : commitLabel(status)) {
                    begin($committing) { await commit() }
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

    // MARK: - Pull request

    // Per the canvas: no pull request → a title, the sentence that says
    // creating pushes first, one amber Create, and "Link an existing one".
    // With one → its title and state, one amber Open in GitHub. Trouble
    // with gh on the computer is the host's sentence, and no button.
    @ViewBuilder
    private var pullRequestTab: some View {
        switch pullRequest {
        case .loading:
            LoadingRow("Asking GitHub on \(computerName ?? "the computer")…", font: .subheadline)
        case let .failed(reason):
            MessageCard(reason, identifier: "sourceControl.pr.failed", font: .subheadline)
        case let .loaded(status):
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let pr = status.pullRequest {
                        existingPullRequest(pr)
                    } else if !status.gh.ok {
                        Text("Pull requests need GitHub CLI on \(computerName ?? "the computer")")
                            .font(.headline)
                            .foregroundStyle(TaviTheme.textPrimary)
                        Text(status.gh.reason ?? "gh could not answer.")
                            .font(.subheadline)
                            .foregroundStyle(TaviTheme.textSecondary)
                            .padding(.top, 6)
                            .accessibilityIdentifier("sourceControl.pr.ghTrouble")
                    } else {
                        noPullRequest(status)
                    }
                    if let pullRequestNotice {
                        Text(pullRequestNotice)
                            .font(.footnote)
                            .foregroundStyle(TaviTheme.textSecondary)
                            .padding(.top, 20)
                            .accessibilityIdentifier("sourceControl.pr.notice")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 18)
            }
        }
    }

    private func noPullRequest(_ status: PullRequestStatus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("No pull request yet")
                .font(.headline)
                .foregroundStyle(TaviTheme.textPrimary)
                .accessibilityIdentifier("sourceControl.pr.none")
            Text(createSentence(status))
                .font(.subheadline)
                .foregroundStyle(TaviTheme.textSecondary)
                .padding(.top, 6)
            if status.remote != nil, status.branch != nil {
                // Prefilled from the newest commit over the base: with
                // several commits gh would otherwise title the pull request
                // after the branch (`demo/79 pr`) (#83). Cleared, gh fills.
                TextField("Title", text: $pullRequestTitle, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.subheadline)
                    .foregroundStyle(TaviTheme.textPrimary)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(TaviTheme.groupFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 20)
                    .accessibilityIdentifier("sourceControl.pr.title")
                Button(creatingPullRequest ? "Creating…" : "Create pull request") {
                    begin($creatingPullRequest) { await createPullRequest() }
                }
                .buttonStyle(.taviProminent)
                .disabled(creatingPullRequest || linking)
                .padding(.top, 16)
                .accessibilityIdentifier("sourceControl.pr.create")
                Button(linking ? "Linking…" : "Link an existing one") {
                    linkReference = ""
                    askingForLink = true
                }
                .font(.subheadline)
                .foregroundStyle(TaviTheme.textSecondary)
                .disabled(creatingPullRequest || linking)
                .padding(.top, 16)
                .padding(.leading, 4)
                .accessibilityIdentifier("sourceControl.pr.link")
            }
        }
    }

    private func createSentence(_ status: PullRequestStatus) -> String {
        guard status.branch != nil else { return "This worktree is not on a branch, so there is nothing to open a pull request for." }
        guard let remote = status.remote else { return "This repository has no remote, so there is nowhere to open a pull request. Add one on the computer first." }
        switch status.unpushed {
        case 0: return "Everything on this branch is on \(remote). Creating a pull request opens it against \(worktreeBase)."
        case 1: return "1 commit on this branch isn't on \(remote). Creating a pull request pushes it first."
        default: return "\(status.unpushed) commits on this branch aren't on \(remote). Creating a pull request pushes them first."
        }
    }

    private var worktreeBase: String {
        if case let .loaded(status) = status, let base = status.base { return base }
        return "the base branch"
    }

    private func existingPullRequest(_ pr: PullRequestInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(pr.title.isEmpty ? "Pull request #\(pr.number)" : pr.title)
                .font(.headline)
                .foregroundStyle(TaviTheme.textPrimary)
                .accessibilityIdentifier("sourceControl.pr.title")
            Text(pr.stateLine)
                .font(.footnote)
                .foregroundStyle(TaviTheme.textSecondary)
                .padding(.top, 6)
            if let signals = pr.signalsLine {
                HStack(spacing: 8) {
                    Circle()
                        .fill(signalColor(pr))
                        .frame(width: 6, height: 6)
                    Text(signals)
                }
                .font(.footnote)
                .foregroundStyle(TaviTheme.textSecondary)
                .padding(.top, 6)
            }
            if pr.changedFiles > 0 {
                HStack(spacing: 6) {
                    Text(pr.changedFiles == 1 ? "1 file" : "\(pr.changedFiles) files")
                    Text("+\(pr.additions)").foregroundStyle(TaviTheme.statusDone)
                    Text("−\(pr.deletions)").foregroundStyle(TaviTheme.diffRemoved)
                }
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(TaviTheme.textSecondary)
                .padding(.top, 6)
            }
            if let url = URL(string: pr.url) {
                Button("Open in GitHub") { openURL(url) }
                    .buttonStyle(.taviProminent)
                    .padding(.top, 24)
                    .accessibilityIdentifier("sourceControl.pr.open")
            }
        }
    }

    private func signalColor(_ pr: PullRequestInfo) -> Color {
        switch pr.checks {
        case "failing": TaviTheme.diffRemoved
        case "pending": TaviTheme.textSecondary
        default: pr.review == "changes-requested" ? TaviTheme.diffRemoved : TaviTheme.statusDone
        }
    }

    private func loadPullRequest(quietly: Bool = false) async {
        guard let client else {
            pullRequest = .failed("Connect a computer first.")
            return
        }
        switch await client.pullRequest(path: worktree.info.path) {
        case let .value(fresh):
            if fresh.pullRequest == nil, pullRequestTitle.isEmpty {
                if case .loading = log { await loadLog(quietly: true) }
                if case let .loaded(log) = log, let newest = log.ahead.first { pullRequestTitle = newest.summary }
            }
            if case let .loaded(current) = pullRequest, current == fresh { return }
            pullRequest = .loaded(fresh)
        case let .refused(_, reason): if !quietly { pullRequest = .failed(reason) }
        case let .failure(reason): if !quietly { pullRequest = .failed(reason) }
        }
    }

    private func createPullRequest() async {
        guard let client else { return }
        let title = pullRequestTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await client.createPullRequest(path: worktree.info.path, title: title.isEmpty ? nil : title, body: nil) {
        case let .value(receipt):
            let pushed = receipt.pushed ?? 0
            pullRequestNotice = pushed > 0
                ? "Pushed \(pushed == 1 ? "1 commit" : "\(pushed) commits") and opened pull request #\(receipt.pullRequest.number)."
                : "Opened pull request #\(receipt.pullRequest.number)."
        case let .refused(_, reason), let .failure(reason):
            pullRequestNotice = reason
        }
        await loadPullRequest()
        await load(quietly: true)
    }

    private func linkPullRequest() async {
        guard let client else { return }
        let reference = linkReference.trimmingCharacters(in: .whitespaces)
        linkReference = ""
        guard !reference.isEmpty else { return }
        switch await client.linkPullRequest(path: worktree.info.path, reference: reference) {
        case let .value(receipt):
            pullRequestNotice = "Linked pull request #\(receipt.pullRequest.number)."
        case let .refused(_, reason), let .failure(reason):
            pullRequestNotice = reason
        }
        await loadPullRequest()
    }

    // MARK: - Commits

    // Per the canvas: "N AHEAD OF MAIN · Push" over the branch's commits,
    // "N BEHIND MAIN · Pull main in" over the base's. Both actions are
    // text in the section header — the tab's job is reading the list.
    @ViewBuilder
    private var commitsTab: some View {
        switch log {
        case .loading:
            LoadingRow("Reading commits on \(computerName ?? "the computer")…", font: .subheadline)
        case let .failed(reason):
            MessageCard(reason, identifier: "sourceControl.commitsFailed", font: .subheadline)
        case let .loaded(log):
            let base = log.base ?? "the base"
            VStack(spacing: 0) {
                if log.ahead.isEmpty, log.behind.isEmpty {
                    MessageCard(log.base == nil ? "\(worktree.info.title) has no base branch to compare with." : "\(worktree.info.title) is level with \(base).", identifier: "sourceControl.commitsEmpty", font: .subheadline)
                } else {
                    List {
                        if !log.ahead.isEmpty {
                            Section {
                                ForEach(log.ahead) { commit in
                                    commitRow(commit, dimmed: false)
                                        .listRowBackground(TaviTheme.card)
                                }
                            } header: {
                                SectionHeader(title: log.ahead.count == 1 ? "1 ahead of \(base)" : "\(log.ahead.count) ahead of \(base)") {
                                    Button(pushLabel(log)) { begin($pushing) { await push() } }
                                        .disabled(pushing || pulling || !canPush(log))
                                        .accessibilityIdentifier("sourceControl.push")
                                }
                            } footer: {
                                if log.truncated { Text("Showing the first 100 commits.") }
                            }
                        }
                        if !log.behind.isEmpty {
                            Section {
                                ForEach(log.behind) { commit in
                                    commitRow(commit, dimmed: true)
                                        .listRowBackground(TaviTheme.card)
                                }
                            } header: {
                                SectionHeader(title: log.behind.count == 1 ? "1 behind \(base)" : "\(log.behind.count) behind \(base)") {
                                    Button(pulling ? "Pulling…" : "Pull \(base) in") { begin($pulling) { await pullBase() } }
                                        .disabled(pushing || pulling)
                                        .accessibilityIdentifier("sourceControl.pullBase")
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
                if let commitsNotice {
                    Text(commitsNotice)
                        .font(.footnote)
                        .foregroundStyle(TaviTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .accessibilityIdentifier("sourceControl.commitsNotice")
                }
            }
        }
    }

    private func commitRow(_ commit: CommitSummary, dimmed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(commit.summary)
                .font(.subheadline)
                .foregroundStyle(dimmed ? TaviTheme.textPrimary.opacity(0.7) : TaviTheme.textPrimary)
                .lineLimit(2)
            HStack(spacing: 0) {
                Text("\(commit.author) · \(commit.age()) · ")
                Text(commit.shortSha)
                    .font(.footnote.monospaced())
            }
            .font(.footnote)
            .foregroundStyle(TaviTheme.textSecondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sourceControl.commit.\(commit.shortSha)")
    }

    private func canPush(_ log: WorktreeLog) -> Bool {
        guard log.branch != nil else { return false }
        if let upstream = log.upstream { return upstream.ahead > 0 }
        return log.remote != nil
    }

    private func pushLabel(_ log: WorktreeLog) -> String {
        if pushing { return "Pushing…" }
        if log.upstream == nil, log.remote == nil { return "No remote" }
        if let upstream = log.upstream, upstream.ahead == 0 { return "Pushed" }
        return "Push"
    }

    private func loadLog(quietly: Bool = false) async {
        guard let client else {
            log = .failed("Connect a computer first.")
            return
        }
        switch await client.log(path: worktree.info.path) {
        case let .value(fresh):
            if case let .loaded(current) = log, current == fresh { return }
            log = .loaded(fresh)
        case let .refused(_, reason): if !quietly { log = .failed(reason) }
        case let .failure(reason): if !quietly { log = .failed(reason) }
        }
    }

    private func push() async {
        guard let client else { return }
        switch await client.push(path: worktree.info.path) {
        case let .value(receipt):
            commitsNotice = "Pushed \(receipt.pushed == 1 ? "1 commit" : "\(receipt.pushed) commits") to \(receipt.upstream)."
        case let .refused(_, reason), let .failure(reason):
            commitsNotice = reason
        }
        await loadLog()
        await load(quietly: true)
    }

    private func pullBase() async {
        guard let client else { return }
        switch await client.pullBase(path: worktree.info.path) {
        case let .value(receipt):
            let base = { if case let .loaded(log) = log { log.base } else { nil } }() ?? "the base"
            // An older host, or one that could not fetch, merged the base
            // as it stood on the computer; said so (#83).
            let asOf = receipt.fetched == true ? "" : " as of the computer's last fetch"
            commitsNotice = receipt.merged == 0
                ? "Nothing to pull in from \(base)\(asOf)."
                : "Pulled \(receipt.merged == 1 ? "1 commit" : "\(receipt.merged) commits") from \(base)\(receipt.fastForward ? "" : " with a merge commit")\(asOf)."
        case let .refused(_, reason), let .failure(reason):
            commitsNotice = reason
        }
        await loadLog()
        await load(quietly: true)
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

    // A tap on a partly staged file stages the rest, as an indeterminate
    // checkbox does everywhere else; only a fully staged file unstages.
    private func toggle(_ file: ChangedFile) async {
        guard let client else { return }
        let outcome = file.staged && !file.unstaged
            ? await client.unstage(path: worktree.info.path, files: [file.path])
            : await client.stage(path: worktree.info.path, files: [file.path])
        report(outcome)
        await load()
    }

    private func stageAll(_ status: WorktreeStatus) async {
        guard let client else { return }
        let outcome = Self.isFullyStaged(status)
            ? await client.unstage(path: worktree.info.path, files: status.files.map(\.path))
            : await client.stageAll(path: worktree.info.path)
        report(outcome)
        await load()
    }

    private func writeMessage() async {
        guard let client else { return }
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
}
