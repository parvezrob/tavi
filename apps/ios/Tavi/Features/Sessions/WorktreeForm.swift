import SwiftUI

// Worktree mode (#75, approved design): Repository, Start from, Branch,
// and a sentence that says exactly what will happen before it happens.
struct WorktreeForm: View {
    @Bindable var draft: NewAgentDraft
    let catalog: ProjectCatalog
    // The person's gh on the chosen computer, for "From a GitHub issue".
    let sourceControl: HostSourceControlClient?

    var body: some View {
        Section {
            Menu {
                ForEach(draft.repos) { repo in
                    Button {
                        draft.worktreeRepo = repo
                        draft.worktreeBase = repo.defaultBranch ?? repo.branches.first
                    } label: {
                        if draft.worktreeRepo?.id == repo.id {
                            Label(repo.name, systemImage: "checkmark")
                        } else {
                            Text(repo.name)
                        }
                    }
                }
            } label: {
                pickerRow("Repository", value: draft.worktreeRepo?.name ?? "Choose")
            }
            .accessibilityIdentifier("newAgent.worktree.repo")

            Menu {
                ForEach(draft.worktreeRepo?.branches ?? [], id: \.self) { branch in
                    Button {
                        draft.worktreeBase = branch
                    } label: {
                        if draft.worktreeBase == branch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                }
            } label: {
                pickerRow("Start from", value: draft.worktreeBase ?? "—")
            }
            .disabled(draft.worktreeRepo == nil)
            .accessibilityIdentifier("newAgent.worktree.base")

            TextField("fix/what-it-does", text: $draft.worktreeBranch)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.body.monospaced())
                .accessibilityIdentifier("newAgent.worktree.branch")

            // "From a GitHub issue" (#79): the repository's open issues,
            // through the person's gh on that computer; picking one names
            // the branch `issue/<n>-<slug>`. Trouble with gh is one line.
            if let repo = draft.worktreeRepo {
                Menu {
                    if draft.issues.isEmpty {
                        Text(draft.issuesNote ?? "Loading issues…")
                    }
                    ForEach(draft.issues) { issue in
                        Button("#\(issue.number) \(issue.title)") {
                            draft.worktreeBranch = issue.branchName
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "number")
                            .font(.caption)
                        Text("From a GitHub issue")
                            .font(.subheadline)
                    }
                    .foregroundStyle(TaviTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("newAgent.worktree.issue")
                .task(id: repo.id) { await loadIssues(for: repo) }
            }
        } header: {
            Text("New worktree")
        } footer: {
            Text(sentence)
                .font(.footnote)
                .foregroundStyle(TaviTheme.textSecondary)
        }
        .listRowBackground(TaviTheme.card)
    }

    private func loadIssues(for repo: RepoInfo) async {
        draft.issues = []
        draft.issuesNote = nil
        guard let sourceControl else {
            draft.issuesNote = "Connect a computer first."
            return
        }
        switch await sourceControl.issues(repo: repo.root) {
        case let .value(list):
            draft.issues = list.issues
            draft.issuesNote = list.gh.ok ? (list.issues.isEmpty ? "No open issues on \(repo.name)." : nil) : list.gh.reason
        case let .refused(_, reason), let .failure(reason):
            draft.issuesNote = reason
        }
    }

    private func pickerRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(TaviTheme.textPrimary)
            Spacer()
            Text(value)
                .foregroundStyle(TaviTheme.textSecondary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(TaviTheme.textSecondary)
        }
        .contentShape(Rectangle())
    }

    private var sentence: String {
        guard let repo = draft.worktreeRepo else { return "Pick the repository to make the worktree in." }
        let branch = draft.worktreeBranch.trimmingCharacters(in: .whitespaces)
        guard !branch.isEmpty else { return "Name the branch. The worktree is created beside \(repo.name), off \(draft.worktreeBase ?? "its default branch")." }
        let kind = draft.agentKind.map { ProjectPicker.label(for: $0, in: catalog) } ?? "the agent"
        return "Creates a worktree beside \(repo.name) on a new branch \(branch) off \(draft.worktreeBase ?? "its default branch"), copies its ignored setup files such as .env, then starts \(kind) there."
    }
}
