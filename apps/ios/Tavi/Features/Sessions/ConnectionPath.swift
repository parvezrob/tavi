import Foundation

// How the phone's packets reach the computer, per the computer's own
// Tailscale (#86 / #84): said in words, never coloured as a problem — a
// relay is slower and still private.
enum ConnectionPath: Equatable, Sendable {
    case direct
    case relay(String?)
    case unknown

    init(path: String?, relay: String?) {
        switch path {
        case "direct": self = .direct
        case "relay": self = .relay(relay.flatMap { $0.isEmpty ? nil : $0 })
        default: self = .unknown
        }
    }

    // The word that joins "Live · 7 ms" on the header; nothing for direct,
    // which is the ordinary case and needs no comment.
    var headerSuffix: String? {
        if case .relay = self { return "relay" }
        return nil
    }

    // The sentence on the computer sheet's "Right now" footer.
    var sentence: String? {
        switch self {
        case .direct: "Direct to this computer — the fastest path there is."
        case let .relay(region): "Through a Tailscale relay\(region.map { " (\($0))" } ?? "") — slower, still private. Usual on mobile networks; at home it means the two devices cannot see each other directly on the WiFi."
        case .unknown: nil
        }
    }
}
