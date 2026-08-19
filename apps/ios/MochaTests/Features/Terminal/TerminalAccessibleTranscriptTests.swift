import Foundation
import Testing
@testable import Mocha

struct TerminalAccessibleTranscriptTests {
    @Test
    func preservesReadableUnicodeAcrossSplitControlSequences() {
        var transcript = TerminalAccessibleTranscript(maximumScalars: 128)

        transcript.append(Data("\u{1B}[1;3".utf8))
        transcript.append(Data("2mPASS\u{1B}[0m · বাংলা · 日本語 · 👩🏽‍💻\r\n".utf8))

        #expect(transcript.value == "PASS · বাংলা · 日本語 · 👩🏽‍💻\n")
    }

    @Test
    func boundsTheAccessibleTranscript() {
        var transcript = TerminalAccessibleTranscript(maximumScalars: 8)

        transcript.append(Data("0123456789".utf8))

        #expect(transcript.value == "23456789")
    }
}
