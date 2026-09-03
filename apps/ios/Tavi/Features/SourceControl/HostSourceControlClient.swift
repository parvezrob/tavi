import Foundation

// The phone's side of the host's Source Control routes (#77; protocol/
// README.md `/api/worktrees/status|stage|unstage|commit|commit-message`).
// One client per paired computer, handed out by its AgentDirectory so the
// credential never leaves that owner. These are the first git *writes* the
// phone can ask for; each is one explicit tap on the sheet.
struct HostSourceControlClient: Sendable {
    private let client: HostClient

    init(
        endpoint: HostEndpoint,
        credential: String,
        transport: @escaping HostClient.Transport = { try await HostSession.shared.data(for: $0) }
    ) {
        client = HostClient(endpoint: endpoint, credential: credential, transport: transport)
    }

    private static let sentences = HostClient.Sentences(
        answer: "an answer",
        tooOld: "This computer's Tavi host is too old for Source Control. Update it with `npx tavi-host update`."
    )

    enum Outcome<Value: Sendable>: Sendable {
        case value(Value)
        // The host's own sentence: nothing staged, no identity, a refusal.
        case refused(status: Int, String)
        case failure(String)
    }

    func status(path: String) async -> Outcome<WorktreeStatus> {
        await send("/api/worktrees/status", method: "GET", query: ["path": path], body: nil)
    }

    func stage(path: String, files: [String]) async -> Outcome<StagedCount> {
        await send("/api/worktrees/stage", method: "POST", query: [:], body: ["path": path, "files": files])
    }

    func stageAll(path: String) async -> Outcome<StagedCount> {
        await send("/api/worktrees/stage", method: "POST", query: [:], body: ["path": path, "files": "all"])
    }

    func unstage(path: String, files: [String]) async -> Outcome<StagedCount> {
        await send("/api/worktrees/unstage", method: "POST", query: [:], body: ["path": path, "files": files])
    }

    func commit(path: String, message: String) async -> Outcome<CommitReceipt> {
        await send("/api/worktrees/commit", method: "POST", query: [:], body: ["path": path, "message": message])
    }

    func writeMessage(path: String) async -> Outcome<WrittenMessage> {
        await send("/api/worktrees/commit-message", method: "POST", query: [:], body: ["path": path])
    }

    // Commits (#78): the branch over and under its base, Push, Pull main in.
    func log(path: String) async -> Outcome<WorktreeLog> {
        await send("/api/worktrees/log", method: "GET", query: ["path": path], body: nil)
    }

    func push(path: String) async -> Outcome<PushReceipt> {
        await send("/api/worktrees/push", method: "POST", query: [:], body: ["path": path])
    }

    func pullBase(path: String) async -> Outcome<PullReceipt> {
        await send("/api/worktrees/pull-base", method: "POST", query: [:], body: ["path": path])
    }

    // Pull request (#79): read, create (the host pushes first), link.
    func pullRequest(path: String) async -> Outcome<PullRequestStatus> {
        await send("/api/worktrees/pull-request", method: "GET", query: ["path": path], body: nil)
    }

    func createPullRequest(path: String, title: String?, body: String?) async -> Outcome<PullRequestReceipt> {
        var payload: [String: Any] = ["path": path]
        if let title, !title.isEmpty { payload["title"] = title }
        if let body, !body.isEmpty { payload["body"] = body }
        return await send("/api/worktrees/pull-request", method: "POST", query: [:], body: payload)
    }

    // A bare number goes as `number`, anything else as `url` — the two
    // shapes protocol/README.md documents.
    func linkPullRequest(path: String, reference: String) async -> Outcome<PullRequestReceipt> {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any] = ["path": path]
        if let number = Self.pullRequestNumber(in: trimmed) {
            body["number"] = number
        } else {
            body["url"] = trimmed
        }
        return await send("/api/worktrees/pull-request/link", method: "POST", query: [:], body: body)
    }

    static func pullRequestNumber(in text: String) -> Int? {
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let number = Int(digits), number > 0 else { return nil }
        return number
    }

    // Open issues for naming a branch (#79; the create sheet).
    func issues(repo: String) async -> Outcome<IssueList> {
        await send("/api/repos/issues", method: "GET", query: ["repo": repo], body: nil)
    }

    // Remove (#81): what would be lost, then the removal that repeats the
    // counts back — the guardrail lives on the host.
    func removalPreview(path: String) async -> Outcome<RemovalPreview> {
        await send("/api/worktrees/removal", method: "GET", query: ["path": path], body: nil)
    }

    func remove(path: String, confirm: RemovalPreview, pushFirst: Bool, deleteBranch: Bool?) async -> Outcome<RemovalReceipt> {
        var payload: [String: Any] = [
            "path": path,
            "confirm": ["uncommitted": confirm.uncommitted.files, "unpushed": confirm.unpushed.commits],
            "pushFirst": pushFirst,
        ]
        // The sheet showed the lock as a line and the button said so.
        if confirm.locked { payload["unlock"] = true }
        if let deleteBranch { payload["deleteBranch"] = deleteBranch }
        return await send("/api/worktrees", method: "DELETE", query: [:], body: payload)
    }

    private func send<Value: Decodable & Sendable>(_ route: String, method: String, query: [String: String], body: [String: Any]?) async -> Outcome<Value> {
        // Reads answer in well under 20 s or the link is gone; writes (push,
        // pull, PR create, removal) may legitimately take a minute.
        let reply: HostClient.Reply<Value> = await client.fetch(method, route, query: query, body: body, timeout: method == "GET" ? 20 : 90, saying: Self.sentences)
        return Self.outcome(reply)
    }

    // The host's answer as an Outcome, with the sentence it sent.
    static func interpret<Value: Decodable>(status: Int, data: Data) -> Outcome<Value> {
        outcome(HostClient.reply(status: status, body: data, saying: sentences))
    }

    private static func outcome<Value: Sendable>(_ reply: HostClient.Reply<Value>) -> Outcome<Value> {
        switch reply {
        case let .value(value):
            return .value(value)
        case let .refused(status, sentence, _):
            return .refused(status: status, sentence)
        case let .failure(reason):
            return .failure(reason)
        }
    }
}
