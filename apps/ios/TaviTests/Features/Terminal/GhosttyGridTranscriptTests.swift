import Foundation
@testable import Tavi
import Testing
import UIKit

// The transcript comes from Ghostty's rendered grid, not the byte stream
// (#71). Under herdr's screen diffs a row whose prefix did not change is
// never re-sent; a byte accumulator then only ever saw the tails. Feed a
// real surface exactly that shape and read the accessibility value back.
@MainActor
struct GhosttyGridTranscriptTests {
    @Test
    func screenWithIdenticalPrefixesReadsAsWholeRows() async throws {
        let runtime = try GhosttyRuntime.shared.get()
        let surface = try GhosttyTerminalSurfaceView(
            runtime: runtime,
            fontSize: 12,
            onInput: { _ in },
            onFailure: { _ in }
        )
        defer { surface.shutdown() }
        var grid = TerminalGridSize(columns: 0, rows: 0)
        surface.onGridSizeChange = { grid = $0 }
        surface.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        surface.layoutIfNeeded()

        // Two full rows (short enough for any grid), then a cursor-positioned
        // redraw of only the tails — the cells that changed — as herdr's
        // attach sends them.
        surface.receive(Data("\u{1B}[2J\u{1B}[Hout 1111\r\nout 2222".utf8))
        surface.receive(Data("\u{1B}[1;5H3333\u{1B}[2;5H4444".utf8))

        var value = ""
        for _ in 0..<40 where !value.contains("4444") {
            try await Task.sleep(for: .milliseconds(100))
            value = surface.accessibilityValue ?? ""
        }

        #expect(grid.columns >= 8, "grid \(grid)")
        #expect(value == "out 3333\nout 4444", "grid \(grid)")
    }
}
