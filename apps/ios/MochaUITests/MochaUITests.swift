import XCTest

final class MochaUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPresentsTheHonestTerminalDevelopmentJourney() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["No Paired Computers"].waitForExistence(timeout: 3))
        app.buttons["sessions.openTerminal"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["connection.sheet"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.secureTextFields["connection.token"].exists)
        app.buttons["Done"].tap()

        XCTAssertTrue(app.otherElements["terminal.surface"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["terminal.composer"].exists)
        XCTAssertFalse(app.buttons["terminal.send"].isEnabled)
        XCTAssertTrue(app.staticTexts["Not connected"].exists)
    }

    @MainActor
    func testRepeatedlyFeedsCreatesAndDestroysTerminalSurface() throws {
        let app = XCUIApplication()
        let corpusData = try JSONEncoder().encode(try rendererStressChunks())
        app.launchEnvironment["MOCHA_DEV_RENDERER_STRESS_CHUNKS"] = String(
            decoding: corpusData,
            as: UTF8.self
        )
        app.launch()

        for iteration in 0..<8 {
            XCTAssertTrue(app.buttons["sessions.openTerminal"].waitForExistence(timeout: 5))
            app.buttons["sessions.openTerminal"].tap()
            XCTAssertTrue(
                app.descendants(matching: .any)["connection.sheet"].waitForExistence(timeout: 10)
            )
            app.buttons["Done"].tap()
            let surface = app.otherElements["terminal.surface"]
            XCTAssertTrue(surface.waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 0.75)
            XCTAssertTrue((surface.value as? String)?.contains("streamed output line") == true)

            if iteration == 3 {
                XCUIDevice.shared.press(.home)
                app.activate()
                XCTAssertTrue(app.otherElements["terminal.surface"].waitForExistence(timeout: 5))
            }

            let backButton = app.navigationBars["Terminal"].buttons.element(boundBy: 0)
            XCTAssertTrue(backButton.waitForExistence(timeout: 3))
            backButton.tap()
        }

        XCTAssertTrue(app.staticTexts["No Paired Computers"].exists)
    }

    private func rendererStressChunks() throws -> [String] {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relativePath = "protocol/fixtures/terminal-v1/output-corpus.json"
        while root.path != "/" {
            let fixtureURL = root.appending(path: relativePath)
            if FileManager.default.fileExists(atPath: fixtureURL.path) {
                let corpus = try JSONDecoder().decode(
                    RendererCorpus.self,
                    from: Data(contentsOf: fixtureURL)
                )
                return corpus.cases.flatMap { fixture in
                    Array(
                        repeating: fixture.chunks,
                        count: fixture.repeatCount ?? 1
                    ).flatMap { $0 }
                }
            }
            root.deleteLastPathComponent()
        }
        throw RendererCorpusError.fixtureNotFound
    }
}

private struct RendererCorpus: Decodable {
    let cases: [RendererCorpusFixture]
}

private struct RendererCorpusFixture: Decodable {
    let chunks: [String]
    let repeatCount: Int?

    private enum CodingKeys: String, CodingKey {
        case chunks
        case repeatCount = "repeat"
    }
}

private enum RendererCorpusError: Error {
    case fixtureNotFound
}
