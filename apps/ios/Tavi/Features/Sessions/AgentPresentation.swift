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

    // A reported plain shell (#42): listed and attached like an agent, but
    // it takes commands, not prompts — the composer treats it as a terminal.
    var isShell: Bool { agent == "shell" }

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
        ownTitle ?? HomeGrouping.projectName(of: cwd)
    }

    // The title the agent set, when it says more than the agent name does.
    // Herdr titles a tab with the product name ("Claude Code") by default.
    var ownTitle: String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        let normalized = trimmed.lowercased()
        if normalized == agent.lowercased() || normalized == displayName.lowercased() { return nil }
        return trimmed
    }

    // Under a project header on the home: a shell titles itself with its
    // prompt, which repeats the folder already on screen, so only a real
    // agent's own title earns a line there. Elsewhere (terminal identity,
    // jump sheet) `projectName` keeps a shell's title, which is what tells
    // two shells in one folder apart.
    var meaningfulTitle: String? {
        isShell ? nil : ownTitle
    }

    // The user's own name for the pane's tab (#55): herdr's tab label,
    // kept only when a person plausibly chose it. Herdr's defaults — bare
    // numbers, anything phone-created ("tavi <kind>", "mocha terminal"
    // from before the rename, #62), the command line the pane runs
    // ("claude --resume …"), and echoes of the agent's name — are noise,
    // not identity (#50 live pass: five waiting cards all titled
    // "claude --res…" told the owner nothing).
    var userTabName: String? {
        guard let raw = tabLabel?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if Int(raw) != nil { return nil }
        let lowered = raw.lowercased()
        if lowered == agent.lowercased() || lowered == displayName.lowercased() { return nil }
        // "tavi claude" / "mocha terminal" are the phone's own default
        // labels; "tavi redesign" is still a name someone chose.
        for prefix in ["tavi ", "mocha "] {
            let rest = lowered.dropFirst(prefix.count)
            if lowered.hasPrefix(prefix),
               [agent.lowercased(), displayName.lowercased(), "terminal", "shell"].contains(String(rest)) {
                return nil
            }
        }
        // A command line: starts with the agent's binary, or carries flags.
        if lowered.hasPrefix(agent.lowercased() + " ") || lowered.contains(" --") || lowered.hasPrefix("-") {
            return nil
        }
        return raw
    }

    // The line under the agent's name wherever the folder is already on
    // screen: your name for the task first, the agent's own title second.
    var secondaryIdentity: String? {
        userTabName ?? meaningfulTitle
    }
}

// Status language and color live in one place; an unrecognized status is
// labeled honestly rather than guessed (PRD: never fabricate state).
struct AgentStatusStyle: Equatable {
    let label: String
    let color: Color

    static func of(_ status: String) -> AgentStatusStyle {
        switch status {
        case "blocked": AgentStatusStyle(label: "Needs you", color: TaviTheme.statusBlocked)
        case "working": AgentStatusStyle(label: "Working", color: TaviTheme.statusWorking)
        case "done": AgentStatusStyle(label: "Done", color: TaviTheme.statusDone)
        case "idle": AgentStatusStyle(label: "Idle", color: TaviTheme.statusIdle)
        default: AgentStatusStyle(label: "Unknown", color: TaviTheme.statusIdle)
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
    // never let a container reuse one cached under the bare pane id — and
    // two computers can each have a pane with the same id (#50).
    var cardIdentity: String { "\(hostId)|\(id)|\(status)" }

    // The unique address of an agent across every paired computer.
    var target: AgentTarget { AgentTarget(hostId: hostId, paneId: id) }

    var abbreviatedPath: String { cwd.abbreviatingHomeDirectory }

    func withStatus(_ status: String) -> AgentSummary {
        AgentSummary(
            id: id,
            agent: agent,
            status: status,
            cwd: cwd,
            title: title,
            workspaceId: workspaceId,
            tabId: tabId,
            tabLabel: tabLabel,
            focused: focused,
            hostId: hostId
        )
    }
}

// Host + pane: the only thing that names one agent once a phone holds
// several computers (#50). Phase E (push notifications, deep links) must
// carry both halves in its payload and resolve them through HostFleet —
// a pane id on its own is ambiguous and the navigation map forbids
// duplicate targets. Noted here; not built yet.
struct AgentTarget: Equatable, Hashable, Sendable {
    let hostId: String
    let paneId: String
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
