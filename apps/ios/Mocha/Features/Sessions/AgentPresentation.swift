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

    var displayName: String {
        switch agent {
        case "claude": "Claude Code"
        case "codex": "Codex"
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
