import Foundation

// Wire shapes of the host's read-only file routes (protocol/README.md:
// `/api/changes`, `/api/files…`). Decoded as-is; presentation decides words.

struct ChangedFile: Identifiable, Equatable, Decodable, Sendable {
    let path: String
    let code: String
    let state: String
    let staged: Bool
    let unstaged: Bool
    let additions: Int?
    let deletions: Int?
    let from: String?
    let secret: Bool

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var directory: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "" : parent
    }

    // One word for the trailing slot; the host's vocabulary, capitalised.
    var stateLabel: String {
        switch state {
        case "modified": "Modified"
        case "added": "Added"
        case "deleted": "Deleted"
        case "renamed": "Renamed"
        case "untracked": "New"
        case "conflict": "Conflict"
        default: "Changed"
        }
    }
}

struct ChangesResponse: Decodable, Sendable {
    let repository: String
    let branch: String?
    let files: [ChangedFile]
    let truncated: Bool
}

struct FileDiff: Decodable, Sendable, Equatable {
    let path: String
    let diff: String
    let truncated: Bool
    let binary: Bool
}

enum FilePreviewKind: String, Decodable, Sendable {
    case text, image, pdf, binary, secret, directory
}

struct FileStatInfo: Decodable, Sendable, Equatable {
    let path: String
    let relativePath: String
    let name: String
    let kind: String
    let size: Int
    let modifiedAt: String
    let preview: FilePreviewKind
    let mime: String
}

struct DirectoryEntry: Identifiable, Decodable, Sendable, Equatable {
    let name: String
    let kind: String
    let size: Int
    let ignored: Bool
    let preview: FilePreviewKind

    var id: String { name }
    var isDirectory: Bool { kind == "directory" }
}

struct DirectoryListing: Decodable, Sendable, Equatable {
    let path: String
    let relativePath: String
    let entries: [DirectoryEntry]
    let truncated: Bool
}

struct FileContent: Decodable, Sendable, Equatable {
    let path: String
    let relativePath: String
    let size: Int
    let mime: String
    let encoding: String
    let content: String
    let truncated: Bool
    let lines: Int

    var isMarkdown: Bool { mime == "text/markdown" }
}

// The host's refusal for a file it will not show: which kind and how big,
// so the phone can say "binary, 2.3 MB" rather than "error".
struct FileRefusal: Decodable, Sendable, Equatable {
    let error: String
    let preview: FilePreviewKind?
    let size: Int?
    let mime: String?
    let outsideRoots: Bool?
    let notRepository: Bool?
}

// A path the agent printed, as the phone found it in the transcript (#61):
// the path itself and the `:line` it carried, if any.
struct MentionedPath: Hashable, Sendable {
    let path: String
    let line: Int?

    var display: String { line.map { "\(path):\($0)" } ?? path }
}

// Finds path-like tokens in terminal text. Detection happens on the phone,
// from the transcript the terminal already keeps for VoiceOver; nothing
// leaves the device for it. The host then says which of these are real
// files — the scanner only has to be generous without being silly.
enum MentionedPathScanner {
    // A token with at least one slash, or a bare filename with an
    // extension; an optional `:line`. Characters are the ones real paths
    // use; a trailing `.` `,` `)` etc. is prose punctuation, stripped below.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![\w@:/.-])((?:~|\.{1,2})?/?[\w.@+-]+(?:/[\w.@+-]+)+/?|[\w@+-]+\.[A-Za-z][\w]{0,7})(?::(\d{1,6}))?(?![\w/])"#
    )
    private static let maximumPaths = 40

    static func scan(_ text: String) -> [MentionedPath] {
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var found: [MentionedPath] = []
        // Newest first: the last mention is the one the person just read.
        for match in pattern.matches(in: text, range: range).reversed() {
            guard let pathRange = Range(match.range(at: 1), in: text) else { continue }
            var raw = String(text[pathRange])
            // URLs, flags, and the shell's own noise are not files.
            if raw.contains("://") || raw.hasPrefix("-") { continue }
            // Trailing only: a leading "." is `./relative`, not punctuation.
            while let last = raw.last, ".,;)]}'\"/".contains(last) { raw.removeLast() }
            guard isPlausible(raw) else { continue }
            let line = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) }
            let mention = MentionedPath(path: raw, line: line)
            if seen.insert(mention.display).inserted {
                found.append(mention)
                if found.count == maximumPaths { break }
            }
        }
        return found
    }

    // Weeds out the lookalikes prose and tool output produce: version
    // numbers (1.2.3), decimal quantities (3.5), domain-ish words the
    // regex cannot tell from files (example.com), and lone dots.
    static func isPlausible(_ candidate: String) -> Bool {
        guard candidate.count >= 3, candidate.count <= 512 else { return false }
        if candidate == "." || candidate == ".." || candidate == "~" { return false }
        let components = candidate.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return false }
        if components.allSatisfy({ $0.allSatisfy { $0.isNumber || $0 == "." } }) { return false }
        if components.count == 1, let name = components.first {
            let parts = name.split(separator: ".")
            guard parts.count >= 2, let ext = parts.last else { return false }
            if parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false }
            let lowered = ext.lowercased()
            // Common hostnames and abbreviations that look like files.
            if ["com", "org", "net", "io", "dev", "ai", "co", "app", "uk", "us", "edu", "gov", "e", "g", "i"].contains(lowered) { return false }
            if name.hasSuffix(".") { return false }
        }
        return true
    }
}
