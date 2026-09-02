import Foundation
import GhosttyKit

// The terminal's text as rendered: what VoiceOver reads and what "Files
// mentioned" (#61) and the Preview port scan (#58) look through.
//
// This reads Ghostty's grid instead of accumulating the byte stream (#71).
// Terminals reach the phone through herdr's attach, which sends screen
// diffs — cursor moves and the cells that changed — not the program's
// bytes. Under sustained output whose rows share a prefix (a log, a test
// runner) only each row's tail ever arrives, so a byte-stream transcript
// degraded to fragments while the screen was right. The grid is what the
// person sees, by construction.
enum GhosttyScreenText {
    // Enough for the largest phone grid several times over; the previous
    // byte window had the same bound.
    static let maximumScalars = 8_192

    // The active area: the rows on screen when not scrolled back. Scrollback
    // is not included — its size is unbounded and it is not what the person
    // is looking at.
    static func activeArea(of surface: ghostty_surface_t) -> String {
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        let raw = String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
        return normalize(raw)
    }

    // Trailing blanks per row and empty rows at the bottom carry no
    // information for a reader or a scanner; the window keeps the end.
    static func normalize(_ raw: String, maximumScalars: Int = maximumScalars) -> String {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            var end = line.endIndex
            while end > line.startIndex, line[line.index(before: end)].isWhitespace {
                end = line.index(before: end)
            }
            return line[line.startIndex..<end]
        }
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        let joined = lines.joined(separator: "\n")
        let scalars = joined.unicodeScalars
        guard scalars.count > maximumScalars else { return joined }
        return String(String.UnicodeScalarView(scalars.suffix(maximumScalars)))
    }
}
