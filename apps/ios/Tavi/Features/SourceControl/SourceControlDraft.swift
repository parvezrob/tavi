import Foundation
import Observation

// Everything the Source Control sheet holds while it is open, and every
// read and write it makes for one worktree (#77, #78, #79, #81; PRD
// §7.12). One object rather than a screenful of flat state, so the three
// tabs can read what they draw instead of taking it apart by parameter
// (#104). The computer and the folder are fixed for the sheet's life, so
// no loader below has to be handed them again.
@MainActor
@Observable
final class SourceControlDraft {
    enum Tab: String, CaseIterable, Identifiable {
        case changes = "Changes"
        case pullRequest = "Pull request"
        case commits = "Commits"
        var id: String { rawValue }
    }

    var tab: Tab = .changes
    var status: Loadable<WorktreeStatus> = .loading
    var message = ""
    var busy: Set<String> = []
    var committing = false
    var writing = false
    var notice: String?
    var openFile: FileTarget?
    // Commits (#78): loaded when the tab is opened, refreshed on the same
    // cadence while it stays open.
    var log: Loadable<WorktreeLog> = .loading
    var pushing = false
    var pulling = false
    var commitsNotice: String?
    // Pull request (#79).
    var pullRequest: Loadable<PullRequestStatus> = .loading
    var creatingPullRequest = false
    var linking = false
    var askingForLink = false
    var linkReference = ""
    var pullRequestNotice: String?
    var pullRequestTitle = ""
    var removing = false
    var removedReceipt: RemovalReceipt?
    // A handle, not something a tab draws: the previous tab's load is
    // cancelled when the selection moves on.
    @ObservationIgnored private var tabLoad: Task<Void, Never>?

    private let client: HostSourceControlClient?
    private let path: String

    init(client: HostSourceControlClient?, path: String) {
        self.client = client
        self.path = path
    }

    // The branch a pull request would open against.
    var worktreeBase: String {
        if case let .loaded(status) = status, let base = status.base { return base }
        return "the base branch"
    }

    // Every write flips its flag on the tap itself, before the Task, so two
    // taps in one frame cannot commit, push, or create twice (the
    // NewAgentSheet rule; #81 review).
    private func begin(_ flag: ReferenceWritableKeyPath<SourceControlDraft, Bool>, _ work: @escaping () async -> Void) {
        guard !self[keyPath: flag] else { return }
        self[keyPath: flag] = true
        Task {
            await work()
            self[keyPath: flag] = false
        }
    }

    private func beginBusy(_ key: String, _ work: @escaping () async -> Void) {
        guard !busy.contains(key) else { return }
        busy.insert(key)
        Task {
            await work()
            busy.remove(key)
        }
    }

    // The tab a tap chose. The load behind it starts and is cancelled here,
    // so nothing outside has to know a tab has a task at all.
    func select(_ tab: Tab) {
        self.tab = tab
        tabLoad?.cancel()
        tabLoad = Task { [self] in
            if tab == .commits { await loadLog() }
            if tab == .pullRequest { await loadPullRequest() }
        }
    }

    func stopLoading() {
        tabLoad?.cancel()
    }

    // MARK: - Changes

    func load(quietly: Bool = false) async {
        guard let client else {
            status = .failed("Connect a computer first.")
            return
        }
        switch await client.status(path: path) {
        case let .value(fresh):
            if case let .loaded(current) = status, current == fresh { return }
            status = .loaded(fresh)
        case let .refused(_, reason): if !quietly { status = .failed(reason) }
        case let .failure(reason): if !quietly { status = .failed(reason) }
        }
    }

    // A tap on a partly staged file stages the rest, as an indeterminate
    // checkbox does everywhere else; only a fully staged file unstages.
    func toggle(_ file: ChangedFile) {
        beginBusy(file.path) { [self] in
            guard let client else { return }
            let outcome = file.staged && !file.unstaged
                ? await client.unstage(path: path, files: [file.path])
                : await client.stage(path: path, files: [file.path])
            report(outcome)
            await load()
        }
    }

    func stageAll(_ status: WorktreeStatus) {
        beginBusy("*") { [self] in
            guard let client else { return }
            let outcome = status.isFullyStaged
                ? await client.unstage(path: path, files: status.files.map(\.path))
                : await client.stageAll(path: path)
            report(outcome)
            await load()
        }
    }

    func writeMessage() {
        begin(\.writing) { [self] in
            guard let client else { return }
            switch await client.writeMessage(path: path) {
            case let .value(written):
                message = written.message
                notice = nil
            case let .refused(_, reason), let .failure(reason):
                notice = reason
            }
        }
    }

    func commit() {
        begin(\.committing) { [self] in
            guard let client else { return }
            switch await client.commit(path: path, message: message) {
            case let .value(receipt):
                message = ""
                notice = "Committed \(receipt.commit.files == 1 ? "1 file" : "\(receipt.commit.files) files"): \(receipt.commit.summary)"
            case let .refused(_, reason), let .failure(reason):
                notice = reason
            }
            await load()
        }
    }

    // MARK: - Pull request

    func loadPullRequest(quietly: Bool = false) async {
        guard let client else {
            pullRequest = .failed("Connect a computer first.")
            return
        }
        switch await client.pullRequest(path: path) {
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

    // Opens the alert that asks for a number or a GitHub link.
    func askForLink() {
        linkReference = ""
        askingForLink = true
    }

    func createPullRequest() {
        begin(\.creatingPullRequest) { [self] in
            guard let client else { return }
            let title = pullRequestTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            switch await client.createPullRequest(path: path, title: title.isEmpty ? nil : title, body: nil) {
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
    }

    func linkPullRequest() {
        begin(\.linking) { [self] in
            guard let client else { return }
            let reference = linkReference.trimmingCharacters(in: .whitespaces)
            linkReference = ""
            guard !reference.isEmpty else { return }
            switch await client.linkPullRequest(path: path, reference: reference) {
            case let .value(receipt):
                pullRequestNotice = "Linked pull request #\(receipt.pullRequest.number)."
            case let .refused(_, reason), let .failure(reason):
                pullRequestNotice = reason
            }
            await loadPullRequest()
        }
    }

    // MARK: - Commits

    func loadLog(quietly: Bool = false) async {
        guard let client else {
            log = .failed("Connect a computer first.")
            return
        }
        switch await client.log(path: path) {
        case let .value(fresh):
            if case let .loaded(current) = log, current == fresh { return }
            log = .loaded(fresh)
        case let .refused(_, reason): if !quietly { log = .failed(reason) }
        case let .failure(reason): if !quietly { log = .failed(reason) }
        }
    }

    func push() {
        begin(\.pushing) { [self] in
            guard let client else { return }
            switch await client.push(path: path) {
            case let .value(receipt):
                commitsNotice = "Pushed \(receipt.pushed == 1 ? "1 commit" : "\(receipt.pushed) commits") to \(receipt.upstream)."
            case let .refused(_, reason), let .failure(reason):
                commitsNotice = reason
            }
            await loadLog()
            await load(quietly: true)
        }
    }

    func pullBase() {
        begin(\.pulling) { [self] in
            guard let client else { return }
            switch await client.pullBase(path: path) {
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
    }

    private func report<Value>(_ outcome: HostSourceControlClient.Outcome<Value>) {
        switch outcome {
        case .value: notice = nil
        case let .refused(_, reason), let .failure(reason): notice = reason
        }
    }
}
