import XCTest

final class MochaUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPresentsTheHonestTerminalDevelopmentJourney() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MOCHA_DEV_RESET"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["No Paired Computers"].waitForExistence(timeout: 3))
        app.buttons["sessions.openTerminal"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["connection.sheet"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.secureTextFields["connection.token"].exists)
        app.buttons["Done"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["terminal.surface"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.descendants(matching: .any)["terminal.disconnected"].exists)
        XCTAssertTrue(app.buttons["terminal.keyboard"].exists)
        XCTAssertFalse(app.buttons["terminal.keyboard"].isEnabled)
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
        app.launchEnvironment["MOCHA_DEV_RESET"] = "1"
        app.launch()

        for iteration in 0..<8 {
            XCTAssertTrue(app.buttons["sessions.openTerminal"].waitForExistence(timeout: 5))
            app.buttons["sessions.openTerminal"].tap()
            let surface = app.descendants(matching: .any)["terminal.surface"]
            XCTAssertTrue(surface.waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 0.75)
            XCTAssertTrue((surface.value as? String)?.contains("streamed output line") == true)

            surface.tap()
            surface.typeText("echo mocha\n")
            app.buttons["terminal.dismissKeyboard"].tap()

            if iteration == 3 {
                XCUIDevice.shared.press(.home)
                app.activate()
                XCTAssertTrue(
                    app.descendants(matching: .any)["terminal.surface"].waitForExistence(timeout: 5)
                )
            }

            let backButton = app.navigationBars["Terminal"].buttons.element(boundBy: 0)
            XCTAssertTrue(backButton.waitForExistence(timeout: 3))
            backButton.tap()
        }

        XCTAssertTrue(app.staticTexts["No Paired Computers"].exists)
    }

    @MainActor
    func testTerminalKeyboardLayout() throws {
        let app = XCUIApplication()
        let corpusData = try JSONEncoder().encode(try rendererStressChunks())
        app.launchEnvironment["MOCHA_DEV_RENDERER_STRESS_CHUNKS"] = String(
            decoding: corpusData,
            as: UTF8.self
        )
        app.launch()

        XCTAssertTrue(app.buttons["sessions.openTerminal"].waitForExistence(timeout: 5))
        app.buttons["sessions.openTerminal"].tap()
        let surface = app.descendants(matching: .any)["terminal.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 5))

        surface.tap()
        surface.typeText("echo mocha")
        keepScreenshot(named: "Terminal with keyboard")

        app.buttons["terminal.dismissKeyboard"].tap()
        keepScreenshot(named: "Terminal without keyboard")
    }

    @MainActor
    func testSustainedTypingRemainsInteractiveUnderOutputLoad() throws {
        let app = XCUIApplication()
        let corpusData = try JSONEncoder().encode(try rendererStressChunks())
        app.launchEnvironment["MOCHA_DEV_RENDERER_STRESS_CHUNKS"] = String(
            decoding: corpusData,
            as: UTF8.self
        )
        app.launch()

        XCTAssertTrue(app.buttons["sessions.openTerminal"].waitForExistence(timeout: 5))
        app.buttons["sessions.openTerminal"].tap()
        let surface = app.descendants(matching: .any)["terminal.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 5))

        surface.tap()
        surface.typeText(String(repeating: "mocha123 ", count: 20))

        let dismissKeyboard = app.buttons["terminal.dismissKeyboard"]
        XCTAssertTrue(dismissKeyboard.waitForExistence(timeout: 3))
        dismissKeyboard.tap()
        XCTAssertTrue(app.navigationBars["Terminal"].exists)
    }

    // Reproduces the live typing loop against a real host: keystrokes must
    // echo to the screen and command output must appear while the keyboard
    // stays up, with no layout change to force a draw. Requires a live
    // connection, so it skips unless TEST_RUNNER_MOCHA_DEV_* variables are
    // set on the xcodebuild invocation.
    @MainActor
    func testLiveTypingEchoesToTheScreenWhileKeyboardIsUp() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["MOCHA_DEV_HOST"],
              let session = environment["MOCHA_DEV_SESSION"],
              let token = environment["MOCHA_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_MOCHA_DEV_HOST/SESSION/TOKEN to run the live echo test.")
        }

        let app = XCUIApplication()
        app.launchEnvironment["MOCHA_DEV_HOST"] = host
        app.launchEnvironment["MOCHA_DEV_SESSION"] = session
        app.launchEnvironment["MOCHA_DEV_TOKEN"] = token
        app.launchEnvironment["MOCHA_DEV_AUTO_OPEN_TERMINAL"] = "1"
        app.launch()

        let surface = app.descendants(matching: .any)["terminal.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForTranscript(of: surface, timeout: 10) { !$0.isEmpty },
            "The connected terminal never rendered its prompt."
        )

        surface.tap()
        let marker = "LIVE-TYPING-ECHO-OK"
        surface.typeText("echo \(marker)\n")

        XCTAssertTrue(
            waitForTranscript(of: surface, timeout: 8) { value in
                value.components(separatedBy: marker).count > 2
            },
            "Typed input and its output did not reach the screen while the keyboard was up."
        )
    }

    // Issue #9: keyboard show/hide during continuous output must not leave
    // stale rows or mis-scaled frames. The test drives the keyboard toggles
    // with long settle windows; visual verification happens through simulator
    // screenshots taken by the harness while it runs, and the transcript
    // assertion proves streaming survived both transitions.
    @MainActor
    func testKeyboardToggleDuringLiveStreamingKeepsReceivingOutput() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["MOCHA_DEV_HOST"],
              let session = environment["MOCHA_DEV_SESSION"],
              let token = environment["MOCHA_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_MOCHA_DEV_HOST/SESSION/TOKEN to run the live resize test.")
        }

        let app = XCUIApplication()
        app.launchEnvironment["MOCHA_DEV_HOST"] = host
        app.launchEnvironment["MOCHA_DEV_SESSION"] = session
        app.launchEnvironment["MOCHA_DEV_TOKEN"] = token
        app.launchEnvironment["MOCHA_DEV_AUTO_OPEN_TERMINAL"] = "1"
        app.launch()

        let surface = app.descendants(matching: .any)["terminal.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForTranscript(of: surface, timeout: 10) { !$0.isEmpty })

        surface.tap()
        Thread.sleep(forTimeInterval: 10)

        app.buttons["terminal.dismissKeyboard"].tap()
        Thread.sleep(forTimeInterval: 8)

        let before = (surface.value as? String) ?? ""
        XCTAssertTrue(
            waitForTranscript(of: surface, timeout: 8) { $0 != before },
            "Streaming output stopped reaching the screen after keyboard toggles."
        )
    }

    // Issue #10: dragging on the terminal scrolls scrollback and never breaks
    // the live stream. Scrollback position is verified visually via harness
    // screenshots during the settle windows; the assertions prove the
    // gesture leaves the surface healthy and still receiving output.
    @MainActor
    func testTouchScrollLeavesStreamingHealthy() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["MOCHA_DEV_HOST"],
              let session = environment["MOCHA_DEV_SESSION"],
              let token = environment["MOCHA_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_MOCHA_DEV_HOST/SESSION/TOKEN to run the live scroll test.")
        }

        let app = XCUIApplication()
        app.launchEnvironment["MOCHA_DEV_HOST"] = host
        app.launchEnvironment["MOCHA_DEV_SESSION"] = session
        app.launchEnvironment["MOCHA_DEV_TOKEN"] = token
        app.launchEnvironment["MOCHA_DEV_AUTO_OPEN_TERMINAL"] = "1"
        app.launch()

        let surface = app.descendants(matching: .any)["terminal.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForTranscript(of: surface, timeout: 10) { !$0.isEmpty })

        surface.swipeDown()
        surface.swipeDown()
        Thread.sleep(forTimeInterval: 6)

        surface.swipeUp()
        surface.swipeUp()
        surface.swipeUp()
        Thread.sleep(forTimeInterval: 4)

        let before = (surface.value as? String) ?? ""
        XCTAssertTrue(
            waitForTranscript(of: surface, timeout: 8) { $0 != before },
            "Streaming output stopped reaching the screen after scroll gestures."
        )
    }

    // Phase C: tapping an agent on the home lands in its pane with an
    // identity header, and the Jump-to sheet lists the hierarchy with the
    // current pane badged. Creates its own disposable agent tab through the
    // host API — never touches agents the owner has running — and closes
    // it again afterwards.
    @MainActor
    func testAgentTerminalShowsIdentityAndJumpSheet() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["MOCHA_DEV_HOST"],
              let token = environment["MOCHA_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_MOCHA_DEV_HOST/TOKEN to run the live jump test.")
        }

        let (paneId, tabId) = try await createAgentTab(host: host, token: token)
        addTeardownBlock {
            try? await Self.closeAgentTab(host: host, token: token, tabId: tabId)
        }

        let app = XCUIApplication()
        app.launchEnvironment["MOCHA_DEV_HOST"] = host
        app.launchEnvironment["MOCHA_DEV_TOKEN"] = token
        app.launch()

        let agentRow = app.buttons["sessions.agent.\(paneId)"]
        XCTAssertTrue(
            agentRow.waitForExistence(timeout: 15),
            "The freshly created agent never appeared on the home."
        )
        agentRow.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["terminal.identity"].waitForExistence(timeout: 8),
            "The agent terminal never showed its identity header."
        )

        let jump = app.buttons["terminal.jump"]
        XCTAssertTrue(jump.waitForExistence(timeout: 3))
        jump.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["terminal.jumpSheet"].waitForExistence(timeout: 5)
        )
        let currentBadge = app.staticTexts["Current"]
        XCTAssertTrue(
            currentBadge.waitForExistence(timeout: 5),
            "The Jump sheet never badged the current pane."
        )
        app.buttons["Done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal.surface"].waitForExistence(timeout: 3))

        // Deliberate composer send to the live agent: the field clears only
        // after the host confirms delivery, so an emptied field proves the
        // prompt endpoint accepted the text.
        let composer = app.textFields["terminal.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        let marker = "COMPOSER-LIVE-OK reply with exactly: COMPOSER-ACK"
        composer.typeText(marker)
        let send = app.buttons["terminal.composerSend"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        let cleared = NSPredicate { _, _ in
            (composer.value as? String).map { $0.isEmpty || !$0.contains("COMPOSER-LIVE-OK") } ?? true
        }
        let expectation = XCTNSPredicateExpectation(predicate: cleared, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 10),
            .completed,
            "The composer never cleared, so the prompt was not confirmed."
        )
    }

    private func createAgentTab(host: String, token: String) async throws -> (paneId: String, tabId: String) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(host)/api/herdr/tabs")))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["agent": "claude"])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 201 else {
            throw XCTSkip("The host could not create a disposable agent tab.")
        }
        let payload = try JSONDecoder().decode([String: String].self, from: data)
        return (try XCTUnwrap(payload["paneId"]), try XCTUnwrap(payload["tabId"]))
    }

    private static func closeAgentTab(host: String, token: String, tabId: String) async throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(host)/api/herdr/tabs/\(tabId)")))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await URLSession.shared.data(for: request)
    }

    @MainActor
    private func waitForTranscript(
        of surface: XCUIElement,
        timeout: TimeInterval,
        until condition: (String) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = surface.value as? String, condition(value) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    @MainActor
    private func keepScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
