import Foundation

// The phone's side of the host's Source Control routes (#77; protocol/
// README.md `/api/worktrees/status|stage|unstage|commit|commit-message`).
// One client per paired computer, handed out by its AgentDirectory so the
// credential never leaves that owner. These are the first git *writes* the
// phone can ask for; each is one explicit tap on the sheet.
struct HostSourceControlClient: Sendable {
    let endpoint: HostEndpoint
    private let credential: String

    init(endpoint: HostEndpoint, credential: String) {
        self.endpoint = endpoint
        self.credential = credential
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }()

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

    private func send<Value: Decodable & Sendable>(_ route: String, method: String, query: [String: String], body: [String: Any]?) async -> Outcome<Value> {
        guard var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false) else {
            return .failure("The host address is invalid.")
        }
        components.path = route
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { return .failure("The host address is invalid.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure("The host did not answer.") }
            guard (200...299).contains(http.statusCode) else {
                if let refusal = try? JSONDecoder().decode(HostSentence.self, from: data) {
                    return .refused(status: http.statusCode, refusal.error)
                }
                if http.statusCode == 404 {
                    return .failure("This computer's Tavi host is too old for Source Control. Update it with `npx tavi-host update`.")
                }
                return .failure("The host could not answer (HTTP \(http.statusCode)).")
            }
            do {
                return .value(try JSONDecoder().decode(Value.self, from: data))
            } catch {
                return .failure("This host sent an answer Tavi does not understand. Update the Tavi host and the app to matching versions.")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private struct HostSentence: Decodable {
        let error: String
    }
}

// Wire shapes (protocol/README.md).
struct WorktreeStatus: Decodable, Sendable, Equatable {
    let path: String
    let branch: String?
    let base: String?
    let ahead: Int
    let behind: Int
    let files: [ChangedFile]
    let staged: Int
    let truncated: Bool
}

struct StagedCount: Decodable, Sendable {
    let staged: Int
}

struct CommitReceipt: Decodable, Sendable, Equatable {
    struct Commit: Decodable, Sendable, Equatable {
        let sha: String
        let summary: String
        let files: Int
    }
    let commit: Commit
}

struct WrittenMessage: Decodable, Sendable {
    let message: String
}

struct CommitSummary: Decodable, Sendable, Equatable, Identifiable {
    let sha: String
    let summary: String
    let author: String
    // ISO 8601 author date, as the host sends it.
    let when: String

    var id: String { sha }
    var shortSha: String { String(sha.prefix(7)) }
    var date: Date? {
        (try? Date(when, strategy: .iso8601)) ?? (try? Date(when, strategy: .iso8601.time(includingFractionalSeconds: true)))
    }

    // "12 min", "1 h", "3 d" — the canvas's register, never a clock glyph.
    func age(now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60)) min"
        case ..<86_400: return "\(Int(seconds / 3600)) h"
        case ..<(86_400 * 30): return "\(Int(seconds / 86_400)) d"
        default:
            return date.formatted(date: .abbreviated, time: .omitted)
        }
    }
}

struct UpstreamInfo: Decodable, Sendable, Equatable {
    let name: String
    let ahead: Int
    let behind: Int
}

struct WorktreeLog: Decodable, Sendable, Equatable {
    let path: String
    let branch: String?
    let base: String?
    let ahead: [CommitSummary]
    let behind: [CommitSummary]
    let upstream: UpstreamInfo?
    let remote: String?
    let truncated: Bool
}

struct PushReceipt: Decodable, Sendable, Equatable {
    let pushed: Int
    let upstream: String
}

struct PullReceipt: Decodable, Sendable, Equatable {
    let merged: Int
    let fastForward: Bool
    let sha: String
}
