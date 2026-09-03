import Foundation
@testable import Tavi
import Testing

struct GhosttyScreenTextTests {
    @Test
    func trimsRowTailsAndBottomBlankRowsKeepsInnerBlankRows() {
        let raw = "streamed output line 1   \nstreamed output line 2\t \n\nsecond block   \n   \n\n"

        #expect(GhosttyScreenText.normalize(raw) == "streamed output line 1\nstreamed output line 2\n\nsecond block")
    }

    @Test
    func keepsTheEndOfTheScreenWhenOverTheWindow() {
        let raw = (0..<100).map { "row \($0) · বাংলা · 👩🏽‍💻" }.joined(separator: "\n")

        let value = GhosttyScreenText.normalize(raw, maximumScalars: 40)

        #expect(value.unicodeScalars.count == 40)
        #expect(raw.hasSuffix(value))
        #expect(value.hasSuffix("row 99 · বাংলা · 👩🏽‍💻"))
    }

    @Test
    func emptyScreenIsEmpty() {
        #expect(GhosttyScreenText.normalize("") == "")
        #expect(GhosttyScreenText.normalize("\n\n   \n") == "")
    }
}
