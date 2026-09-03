import Foundation

enum TerminalQuickKey: String, CaseIterable, Identifiable, Sendable {
    case escape = "Esc"
    case tab = "Tab"
    case shiftTab = "⇧Tab"
    case enter = "Enter"
    case interrupt = "Ctrl-C"
    case left = "←"
    case up = "↑"
    case down = "↓"
    case right = "→"

    var id: Self { self }

    // The key row groups like a keyboard (#54): named keys and the
    // interrupt in one cluster, arrows in another.
    static let commandCluster: [TerminalQuickKey] = [.escape, .tab, .shiftTab, .enter, .interrupt]
    static let arrowCluster: [TerminalQuickKey] = [.left, .up, .down, .right]

    // One key language on the caps: lowercase words, matching the "ctrl"
    // latch beside them ("⌃C" next to a spelled-out ctrl was the audit's
    // exact complaint in new notation; "⏎" appears on no iOS keyboard).
    // Arrows stay arrows — they are their own word.
    var face: String {
        switch self {
        case .escape: "esc"
        case .tab: "tab"
        case .shiftTab: "⇧tab"
        case .enter: "enter"
        case .interrupt: "ctrl-c"
        case .left: "←"
        case .up: "↑"
        case .down: "↓"
        case .right: "→"
        }
    }

    var sequence: String {
        switch self {
        case .escape: "\u{1B}"
        case .tab: "\t"
        case .shiftTab: "\u{1B}[Z"
        case .enter: "\r"
        case .interrupt: "\u{03}"
        case .left: "\u{1B}[D"
        case .up: "\u{1B}[A"
        case .down: "\u{1B}[B"
        case .right: "\u{1B}[C"
        }
    }
}

// Maps a single typed character to its control code (Ctrl-A ... Ctrl-_)
// for the quick-row Ctrl latch. Anything that has no control counterpart
// returns nil and the keystroke passes through unmodified.
enum TerminalControlKeyMapper {
    static func controlCode(for data: Data) -> Data? {
        guard data.count == 1, var byte = data.first else { return nil }
        if (0x61...0x7A).contains(byte) { byte -= 0x20 }
        guard (0x40...0x5F).contains(byte) else { return nil }
        return Data([byte & 0x1F])
    }
}
