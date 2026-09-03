import Foundation
@testable import Tavi
import Testing

struct MentionedPathScannerTests {
    @Test
    func findsRelativeHomeAndLineSuffixedPaths_newestFirst() {
        let text = """
        I wrote the plan to `docs/PLAN.md` and updated ./scripts/build.sh.
        See ~/notes/todo.txt and src/app/main.ts:42 for details.
        error in apps/host/src/server.ts:120:5
        """
        let found = MentionedPathScanner.scan(text).map(\.display)
        #expect(found == ["apps/host/src/server.ts:120", "src/app/main.ts:42", "~/notes/todo.txt", "./scripts/build.sh", "docs/PLAN.md"])
    }

    @Test
    func keepsBareFilenamesWithExtensionsAndDropsProseLookalikes() {
        let text = "Updated README.md and package.json. Version 1.2.3 shipped to example.com, e.g. at 3.5 seconds; see https://tavi.dev/docs/x.md."
        let found = MentionedPathScanner.scan(text).map(\.display)
        #expect(found.contains("README.md"))
        #expect(found.contains("package.json"))
        #expect(!found.contains("1.2.3"))
        #expect(!found.contains("example.com"))
        #expect(!found.contains("3.5"))
        #expect(!found.contains { $0.contains("tavi.dev") })
        #expect(!found.contains { $0.contains("docs/x.md") })
    }

    @Test
    func ignoresFlagsAndDeduplicatesKeepingTheLatestMention() {
        let text = "run --config path/to/x.json\nopen path/to/x.json\nagain path/to/x.json"
        let found = MentionedPathScanner.scan(text)
        #expect(found.map(\.display) == ["path/to/x.json"])
        #expect(!found.contains { $0.path.hasPrefix("-") })
    }

    @Test
    func stripsTrailingProsePunctuation() {
        let found = MentionedPathScanner.scan("Saved (see out/report.html). Then 'lib/util.swift', done.").map(\.display)
        #expect(found == ["lib/util.swift", "out/report.html"])
    }

    @Test
    func plausibilityRules() {
        #expect(MentionedPathScanner.isPlausible("docs/PLAN.md"))
        #expect(MentionedPathScanner.isPlausible("Makefile.in"))
        #expect(!MentionedPathScanner.isPlausible("1.2.3"))
        #expect(!MentionedPathScanner.isPlausible("10.0.0.1"))
        #expect(!MentionedPathScanner.isPlausible("example.com"))
        #expect(!MentionedPathScanner.isPlausible(".."))
    }
}
