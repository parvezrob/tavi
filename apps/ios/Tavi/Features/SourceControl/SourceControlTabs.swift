import SwiftUI

// The two reading tabs of the Source Control sheet (#77; PRD §7.12). Both
// are drawing only: they read the sheet's draft and hand a tap back to it,
// and the draft is the one thing they take (#100, #104).

// Per the canvas: no pull request → a title, the sentence that says
// creating pushes first, one amber Create, and "Link an existing one".
// With one → its title and state, one amber Open in GitHub. Trouble
// with gh on the computer is the host's sentence, and no button.
struct PullRequestTab: View {
    @Bindable var draft: SourceControlDraft
    let computerName: String?

    @Environment(\.openURL) private var openURL

    @ViewBuilder
    var body: some View {
        switch draft.pullRequest {
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
                            .padding(.top, TaviTheme.Spacing.tight)
                            .accessibilityIdentifier("sourceControl.pr.ghTrouble")
                    } else {
                        noPullRequest(status)
                    }
                    if let notice = draft.pullRequestNotice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(TaviTheme.textSecondary)
                            .padding(.top, 20)
                            .accessibilityIdentifier("sourceControl.pr.notice")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TaviTheme.Spacing.screen)
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
                .padding(.top, TaviTheme.Spacing.tight)
            if status.remote != nil, status.branch != nil {
                // Prefilled from the newest commit over the base: with
                // several commits gh would otherwise title the pull request
                // after the branch (`demo/79 pr`) (#83). Cleared, gh fills.
                TextField("Title", text: $draft.pullRequestTitle, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.subheadline)
                    .foregroundStyle(TaviTheme.textPrimary)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, TaviTheme.Spacing.snug)
                    .padding(.vertical, 10)
                    .background(TaviTheme.groupFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 20)
                    .accessibilityIdentifier("sourceControl.pr.title")
                Button(draft.creatingPullRequest ? "Creating…" : "Create pull request") { draft.createPullRequest() }
                    .buttonStyle(.taviProminent)
                    .disabled(draft.creatingPullRequest || draft.linking)
                    .padding(.top, TaviTheme.Spacing.screen)
                    .accessibilityIdentifier("sourceControl.pr.create")
                Button(draft.linking ? "Linking…" : "Link an existing one") { draft.askForLink() }
                    .font(.subheadline)
                    .foregroundStyle(TaviTheme.textSecondary)
                    .disabled(draft.creatingPullRequest || draft.linking)
                    .padding(.top, TaviTheme.Spacing.screen)
                    .padding(.leading, 4)
                    .accessibilityIdentifier("sourceControl.pr.link")
            }
        }
    }

    private func createSentence(_ status: PullRequestStatus) -> String {
        guard status.branch != nil else { return "This worktree is not on a branch, so there is nothing to open a pull request for." }
        guard let remote = status.remote else { return "This repository has no remote, so there is nowhere to open a pull request. Add one on the computer first." }
        switch status.unpushed {
        case 0: return "Everything on this branch is on \(remote). Creating a pull request opens it against \(draft.worktreeBase)."
        case 1: return "1 commit on this branch isn't on \(remote). Creating a pull request pushes it first."
        default: return "\(status.unpushed) commits on this branch aren't on \(remote). Creating a pull request pushes them first."
        }
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
                .padding(.top, TaviTheme.Spacing.tight)
            if let signals = pr.signalsLine {
                HStack(spacing: 8) {
                    Circle()
                        .fill(signalColor(pr))
                        .frame(width: 6, height: 6)
                    Text(signals)
                }
                .font(.footnote)
                .foregroundStyle(TaviTheme.textSecondary)
                .padding(.top, TaviTheme.Spacing.tight)
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
                .padding(.top, TaviTheme.Spacing.tight)
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
}

// Per the canvas: "N AHEAD OF MAIN · Push" over the branch's commits,
// "N BEHIND MAIN · Pull main in" over the base's. Both actions are
// text in the section header — the tab's job is reading the list.
struct CommitsTab: View {
    let draft: SourceControlDraft
    let worktreeTitle: String
    let computerName: String?

    @ViewBuilder
    var body: some View {
        switch draft.log {
        case .loading:
            LoadingRow("Reading commits on \(computerName ?? "the computer")…", font: .subheadline)
        case let .failed(reason):
            MessageCard(reason, identifier: "sourceControl.commitsFailed", font: .subheadline)
        case let .loaded(log):
            let base = log.base ?? "the base"
            VStack(spacing: 0) {
                if log.ahead.isEmpty, log.behind.isEmpty {
                    MessageCard(log.base == nil ? "\(worktreeTitle) has no base branch to compare with." : "\(worktreeTitle) is level with \(base).", identifier: "sourceControl.commitsEmpty", font: .subheadline)
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
                                    Button(pushLabel(log)) { draft.push() }
                                        .disabled(draft.pushing || draft.pulling || !canPush(log))
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
                                    Button(draft.pulling ? "Pulling…" : "Pull \(base) in") { draft.pullBase() }
                                        .disabled(draft.pushing || draft.pulling)
                                        .accessibilityIdentifier("sourceControl.pullBase")
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
                if let notice = draft.commitsNotice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(TaviTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, TaviTheme.Spacing.screen)
                        .padding(.vertical, TaviTheme.Spacing.snug)
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
        if draft.pushing { return "Pushing…" }
        if log.upstream == nil, log.remote == nil { return "No remote" }
        if let upstream = log.upstream, upstream.ahead == 0 { return "Pushed" }
        return "Push"
    }
}

// What the sheet says above its tabs, and what Orca's phone lacks: the
// branch against its base, and the agent living in this worktree.
struct SourceControlHeader: View {
    let repoName: String
    let computerName: String?
    let worktree: HomeWorktree
    let draft: SourceControlDraft

    var body: some View {
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
        .padding(.horizontal, TaviTheme.Spacing.screen)
        .padding(.top, TaviTheme.Spacing.tight)
    }

    private var syncSuffix: String {
        guard case let .loaded(status) = draft.status, let base = status.base else { return "" }
        var parts: [String] = []
        if status.ahead > 0 { parts.append("↑\(status.ahead)") }
        if status.behind > 0 { parts.append("↓\(status.behind)") }
        return parts.isEmpty ? " · up to date with \(base)" : " · \(parts.joined(separator: " ")) vs \(base)"
    }
}
