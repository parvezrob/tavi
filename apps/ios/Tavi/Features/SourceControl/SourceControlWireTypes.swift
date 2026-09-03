import Foundation

// What the host's Source Control routes send, and nothing else (protocol/
// README.md). Split off HostSourceControlClient — a route list and the
// shapes it decodes change for different reasons — when CommitSummary
// grew a decoder (#104).
struct WorktreeStatus: Decodable, Sendable, Equatable {
    let path: String
    let branch: String?
    let base: String?
    let ahead: Int
    let behind: Int
    let files: [ChangedFile]
    let staged: Int
    let truncated: Bool

    // Every file fully staged — only then does the section offer to undo it.
    var isFullyStaged: Bool { files.allSatisfy { $0.staged && !$0.unstaged } }
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
    // The host's ISO 8601 author date, parsed once as the log is decoded:
    // the Commits list re-reads every row's age on every redraw, and
    // parsing there put a date parser in `body` (#104).
    let date: Date?

    private enum CodingKeys: String, CodingKey {
        case sha, summary, author, when
    }

    init(sha: String, summary: String, author: String, when: String) {
        self.sha = sha
        self.summary = summary
        self.author = author
        date = (try? Date(when, strategy: .iso8601)) ?? (try? Date(when, strategy: .iso8601.time(includingFractionalSeconds: true)))
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sha: try fields.decode(String.self, forKey: .sha),
            summary: try fields.decode(String.self, forKey: .summary),
            author: try fields.decode(String.self, forKey: .author),
            when: try fields.decode(String.self, forKey: .when)
        )
    }

    var id: String { sha }
    var shortSha: String { String(sha.prefix(7)) }

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
    // Whether the host fetched the base's upstream before merging (#83);
    // absent from an older host.
    let fetched: Bool?
    // The ref that was merged: the base, or its remote-tracking ref when
    // the base is checked out somewhere and could not be moved.
    let from: String?
}

struct PullRequestInfo: Decodable, Sendable, Equatable {
    let number: Int
    let url: String
    let title: String
    let state: String
    let isDraft: Bool
    let base: String
    let checks: String
    let review: String?
    let additions: Int
    let deletions: Int
    let changedFiles: Int

    // "#12 · open · into main", the state in words a person uses.
    var stateLine: String {
        var parts = ["#\(number)", isDraft && state == "open" ? "draft" : state]
        if !base.isEmpty { parts.append("into \(base)") }
        return parts.joined(separator: " · ")
    }

    // Checks and review as one line; nothing when GitHub has nothing to say.
    var signalsLine: String? {
        var parts: [String] = []
        switch checks {
        case "passing": parts.append("Checks passing")
        case "failing": parts.append("Checks failing")
        case "pending": parts.append("Checks running")
        default: break
        }
        switch review {
        case "approved": parts.append("approved")
        case "changes-requested": parts.append("changes requested")
        case "review-required": parts.append("review needed")
        default: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct GhState: Decodable, Sendable, Equatable {
    let ok: Bool
    let reason: String?
}

struct PullRequestStatus: Decodable, Sendable, Equatable {
    let path: String
    let branch: String?
    let pullRequest: PullRequestInfo?
    let unpushed: Int
    let remote: String?
    let gh: GhState
}

struct PullRequestReceipt: Decodable, Sendable, Equatable {
    let pullRequest: PullRequestInfo
    let pushed: Int?
}

struct IssueSummary: Decodable, Sendable, Equatable, Identifiable {
    let number: Int
    let title: String
    var id: Int { number }

    // `issue/12-login-redirect-loops`: the number keeps it unique, the
    // words keep it readable, and git accepts every character in it.
    var branchName: String {
        let lowered = title.lowercased()
        var slug = ""
        var lastWasDash = true
        for scalar in lowered.unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > 40 {
            // Cut at a word boundary: "…show-when-a-pane-is" read as a
            // glitch on the phone (owner + a cold agent, 2026-09-02). A
            // single word longer than the cap is cut mid-word — better
            // than an empty slug.
            let head = slug.prefix(40)
            let alreadyAtBoundary = slug.dropFirst(40).first == "-"
            if !alreadyAtBoundary, let boundary = head.lastIndex(of: "-"), head.distance(from: head.startIndex, to: boundary) >= 12 {
                slug = String(head[..<boundary])
            } else {
                slug = String(head)
            }
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug.isEmpty ? "issue/\(number)" : "issue/\(number)-\(slug)"
    }
}

struct IssueList: Decodable, Sendable {
    let issues: [IssueSummary]
    let gh: GhState
}

struct RemovalPreview: Decodable, Sendable, Equatable {
    struct Uncommitted: Decodable, Sendable, Equatable {
        let files: Int
        let additions: Int
        let deletions: Int
    }

    struct Unpushed: Decodable, Sendable, Equatable {
        let commits: Int
        let upstream: String?
        let remote: String?
    }

    struct Agent: Decodable, Sendable, Equatable {
        let paneId: String
        let tabId: String
        let kind: String
        let status: String
        // Where it works; the host names it for the agents removal takes
        // down *outside* the worktree.
        let cwd: String?
    }

    let path: String
    let branch: String?
    let isMain: Bool
    // `git worktree lock` — Claude Code locks every worktree it makes.
    let locked: Bool
    let repoRoot: String
    let base: String?
    let uncommitted: Uncommitted
    let unpushed: Unpushed
    let agents: [Agent]
    // Agents elsewhere that share a herdr tab with one inside: the tab
    // closes whole, so they go too (#83). Absent from an older host.
    let alsoClosed: [Agent]?
    let branchMerged: Bool

    var agentsAlsoClosed: [Agent] { alsoClosed ?? [] }

    // Nothing here exists only here: safe to remove without a word of
    // warning beyond the counts.
    var isSafe: Bool { uncommitted.files == 0 && unpushed.commits == 0 }
    var canPushFirst: Bool { unpushed.commits > 0 && remote != nil && branch != nil }
    var remote: String? { unpushed.upstream != nil ? unpushed.upstream : unpushed.remote }
}

struct RemovalReceipt: Decodable, Sendable, Equatable {
    struct Removed: Decodable, Sendable, Equatable {
        let path: String
        let branch: String?
        let branchDeleted: Bool
        let branchKept: String?
        let branchNote: String?
        let closedAgents: Int
        let pushed: Int
    }

    let removed: Removed
}
