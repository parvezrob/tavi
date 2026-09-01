import Foundation

// Wire shapes of the host's dev-server preview routes (#58;
// protocol/README.md `/api/preview…`). Decoded as-is; words are decided by
// the sheet.

struct PreviewDoorInfo: Decodable, Sendable, Equatable {
    let doorPort: Int
    let ready: Bool
    let cookieName: String
}

struct PreviewServer: Identifiable, Decodable, Sendable, Equatable, Hashable {
    let port: Int
    // The process name as the computer knows it: `node`, `python3.12`, `vite`.
    let command: String?
    let cwd: String?

    var id: Int { port }
    var label: String { "localhost:\(port)" }
    var folderName: String? { cwd.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } }

    init(port: Int, command: String? = nil, cwd: String? = nil) {
        self.port = port
        self.command = command
        self.cwd = cwd
    }
}

struct PreviewCandidates: Decodable, Sendable, Equatable {
    let available: Bool
    let reason: String?
    let servers: [PreviewServer]
}

// The ticket comes back exactly once and lives only in the web view's
// cookie jar; nothing here persists it.
struct OpenedPreview: Decodable, Sendable, Equatable {
    let id: String
    let port: Int
    let doorPort: Int
    let cookieName: String
    let ticket: String
}

struct PreviewHeartbeat: Decodable, Sendable, Equatable {
    let id: String
    let port: Int
    let listening: Bool
}

struct PreviewStopped: Decodable, Sendable, Equatable {
    let stopped: Bool
    let pid: Int
    let command: String
}

struct PreviewRefusal: Decodable, Sendable, Equatable {
    let error: String
    let doorMissing: Bool?
    let outsideRoots: Bool?
}
