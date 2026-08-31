import SwiftUI

// The home groups agents by what the user should do about them, not by
// provider internals: blocked work leads, running work follows, and
// finished or parked work drops to the recent list.
enum AgentHomeSection {
    case needsYou
    case active
    case recent
}

extension AgentSummary {
    var homeSection: AgentHomeSection {
        switch status {
        case "blocked": .needsYou
        case "working": .active
        default: .recent
        }
    }

    // Product names for the kinds herdr can launch; the host serves the same
    // labels in the picker, this covers agents that were started elsewhere.
    var displayName: String {
        switch agent {
        case "shell": "Terminal"
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "gemini": "Gemini CLI"
        case "opencode": "OpenCode"
        case "copilot": "GitHub Copilot"
        case "cursor": "Cursor"
        case "amp": "Amp"
        case "droid": "Droid"
        case "kimi": "Kimi"
        case "kiro": "Kiro"
        case "grok": "Grok"
        case "cline": "Cline"
        case "devin": "Devin"
        case "mastracode": "Mastra Code"
        case "qodercli": "Qoder CLI"
        default: agent.capitalized
        }
    }

    // The most recognizable identity line we have: the agent's own title
    // when it set one, otherwise the project directory name. A title that
    // just repeats the agent name (Herdr's default) adds nothing next to
    // displayName, so it falls through to the directory.
    var projectName: String {
        if !title.isEmpty, title.lowercased() != agent.lowercased() { return title }
        let directory = URL(fileURLWithPath: cwd).lastPathComponent
        return directory.isEmpty ? cwd : directory
    }
}

// Status language and color live in one place; an unrecognized status is
// labeled honestly rather than guessed (PRD: never fabricate state).
struct AgentStatusStyle: Equatable {
    let label: String
    let color: Color

    static func of(_ status: String) -> AgentStatusStyle {
        switch status {
        case "blocked": AgentStatusStyle(label: "Needs you", color: MochaTheme.statusBlocked)
        case "working": AgentStatusStyle(label: "Working", color: MochaTheme.statusWorking)
        case "done": AgentStatusStyle(label: "Done", color: MochaTheme.statusDone)
        case "idle": AgentStatusStyle(label: "Idle", color: MochaTheme.statusIdle)
        default: AgentStatusStyle(label: "Unknown", color: MochaTheme.statusIdle)
        }
    }
}

// Presentation-level hysteresis over Herdr's detected status. Live sessions
// flap (done↔blocked↔working within a second) as the TUI redraws, which made
// "Needs you" blink on the home. Escalations (→ blocked, → working) show
// immediately; a de-escalation only commits after the calmer status has been
// continuously observed for `hold` seconds. A waiting agent therefore stays
// "Needs you" until its resolution is real. Raw provenance is untouched —
// this smooths what the phone *shows*, not what the host reports.
@MainActor
final class AgentStatusSmoother {
    private var presented: [String: String] = [:]
    private var deescalationSince: [String: Date] = [:]
    private let hold: TimeInterval

    init(hold: TimeInterval = 5) {
        self.hold = hold
    }

    func reset() {
        presented = [:]
        deescalationSince = [:]
    }

    // Returns the agents with presentation statuses, plus the earliest
    // moment a pending de-escalation matures — callers re-run at that time
    // since no snapshot may arrive to trigger it.
    func apply(_ agents: [AgentSummary], now: Date = Date()) -> (agents: [AgentSummary], nextReview: Date?) {
        var result: [AgentSummary] = []
        var nextReview: Date?
        var nextPresented: [String: String] = [:]
        var nextSince: [String: Date] = [:]

        for agent in agents {
            let raw = agent.status
            let current = presented[agent.id] ?? raw
            var shown = raw
            if Self.rank(raw) < Self.rank(current) {
                let since = deescalationSince[agent.id] ?? now
                if now.timeIntervalSince(since) >= hold {
                    shown = raw
                } else {
                    shown = current
                    nextSince[agent.id] = since
                    let review = since.addingTimeInterval(hold)
                    nextReview = nextReview.map { min($0, review) } ?? review
                }
            }
            nextPresented[agent.id] = shown
            result.append(agent.withStatus(shown))
        }

        presented = nextPresented
        deescalationSince = nextSince
        return (result, nextReview)
    }

    private static func rank(_ status: String) -> Int {
        switch status {
        case "blocked": 3
        case "working": 2
        default: 1
        }
    }
}

extension AgentSummary {
    // View identity for home cards: a status change must rebuild the card,
    // never let a container reuse one cached under the bare pane id.
    var cardIdentity: String { "\(id)|\(status)" }

    // The working directory with the home prefix folded to "~" — the phone
    // doesn't know the host's home, so this is a display heuristic only.
    var abbreviatedPath: String {
        cwd.replacingOccurrences(
            of: "^/(?:Users|home)/[^/]+",
            with: "~",
            options: .regularExpression
        )
    }

    func withStatus(_ status: String) -> AgentSummary {
        AgentSummary(
            id: id,
            agent: agent,
            status: status,
            cwd: cwd,
            title: title,
            workspaceId: workspaceId,
            tabId: tabId,
            focused: focused
        )
    }
}

// Herdr previews arrive as raw terminal text. Stripping escape sequences
// and control characters here means a preview can never restyle, scroll,
// or spoof the surrounding UI — it is quoted text, nothing more.
enum AgentPreviewFormatter {
    static func sanitize(_ raw: String, maxLines: Int = 4) -> String {
        var text = raw
        for pattern in [
            "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)?",
            "\u{1B}\\[[0-9;:?]*[ -/]*[@-~]",
            "\u{1B}[@-_]",
        ] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.unicodeScalars
            .filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }
            .map { String(Character($0)) }
            .joined()

        var lines = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.suffix(maxLines).joined(separator: "\n")
    }
}
