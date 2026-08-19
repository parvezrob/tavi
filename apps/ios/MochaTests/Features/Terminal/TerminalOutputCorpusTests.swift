import Foundation
import Testing

struct TerminalOutputCorpusTests {
    @Test
    func syntheticCorpusCoversRequiredTerminalBehaviorsWithinBoundedSize() throws {
        let corpus = try loadCorpus()
        let names = Set(corpus.cases.map(\.name))

        #expect(corpus.version == 1)
        #expect(names.isSuperset(of: [
            "ansi-and-truecolor",
            "unicode-wide-and-bidi",
            "split-control-sequences",
            "codex-synthetic-redraw",
            "claude-synthetic-redraw",
            "chatty-agent-output",
        ]))

        let expandedByteCount = corpus.cases.reduce(into: 0) { total, fixture in
            total += fixture.chunks.reduce(0) { $0 + Data($1.utf8).count }
                * (fixture.repeatCount ?? 1)
        }
        #expect(expandedByteCount > 10_000)
        #expect(expandedByteCount < 1_048_576)
    }

    private func loadCorpus() throws -> TerminalOutputCorpus {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            root.deleteLastPathComponent()
        }
        let fixtureURL = root
            .appending(path: "protocol/fixtures/terminal-v1/output-corpus.json")
        return try JSONDecoder().decode(
            TerminalOutputCorpus.self,
            from: Data(contentsOf: fixtureURL)
        )
    }
}

private struct TerminalOutputCorpus: Decodable {
    let version: Int
    let cases: [TerminalOutputFixture]
}

private struct TerminalOutputFixture: Decodable {
    let name: String
    let chunks: [String]
    let repeatCount: Int?

    private enum CodingKeys: String, CodingKey {
        case name
        case chunks
        case repeatCount = "repeat"
    }
}
