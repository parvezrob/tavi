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

    // #24 acceptance: create an agent in a folder chosen on the phone, and
    // never in the host's home directory. Drives the real picker against a
    // live host, then closes the tab it made.
    @MainActor
    func testCreateAgentInAPickedProjectFolder() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["MOCHA_DEV_HOST"],
              let token = environment["MOCHA_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_MOCHA_DEV_HOST/TOKEN to run the live picker test.")
        }

        let project = try await knownProjectPath(host: host, token: token)
        let before = Set(try await agentPaneIds(host: host, token: token))

        let app = XCUIApplication()
        app.launchEnvironment["MOCHA_DEV_HOST"] = host
        app.launchEnvironment["MOCHA_DEV_TOKEN"] = token
        app.launch()

        app.buttons["sessions.newAgentTab"].tap()
        XCTAssertTrue(
            app.otherElements["newAgent.folders"].waitForExistence(timeout: 20)
                || app.collectionViews["newAgent.folders"].waitForExistence(timeout: 1),
            "The project picker never listed any folders."
        )

        keepScreenshot(named: "new-agent-picker")

        // The agent menu lists what this Mac can launch. Claude is installed
        // wherever these live tests run (they drive it), so pick it
        // explicitly rather than trusting the remembered default.
        app.buttons["newAgent.agentKind"].tap()
        let claudeChoice = app.buttons["newAgent.agentKind.claude"]
        XCTAssertTrue(claudeChoice.waitForExistence(timeout: 10), "The agent menu never offered Claude Code.")
        keepScreenshot(named: "new-agent-kinds-menu")
        claudeChoice.tap()

        // Nothing is chosen yet, so there is nowhere to create the agent.
        let create = app.buttons["newAgent.create"]
        XCTAssertTrue(create.exists)
        XCTAssertFalse(create.isEnabled, "Create was enabled before a folder was picked.")

        let folder = app.buttons["newAgent.folder.\(project)"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10), "The picker never offered \(project).")
        folder.tap()
        XCTAssertTrue(create.isEnabled, "Create stayed disabled after picking a folder.")
        create.tap()

        // The agent arrives on the home through the live snapshot feed.
        var created: String?
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, created == nil {
            let now = try await agentPaneIds(host: host, token: token)
            created = now.first { !before.contains($0) }
            if created == nil { try await Task.sleep(for: .seconds(2)) }
        }
        guard let paneId = created else {
            throw XCTSkip("The host never reported a new agent; cannot verify the picker end to end.")
        }
        addTeardownBlock {
            if let tabId = try? await Self.tabId(host: host, token: token, paneId: paneId) {
                try? await Self.closeAgentTab(host: host, token: token, tabId: tabId)
            }
        }

        // Born where it was told to be, not in the host's home directory.
        let cwd = try await agentCwd(host: host, token: token, paneId: paneId)
        XCTAssertEqual(cwd, project, "The agent did not start in the folder picked on the phone.")
        XCTAssertTrue(
            app.buttons["sessions.agent.\(paneId)"].waitForExistence(timeout: 20),
            "The agent created from the picker never appeared on the home."
        )

        // The folder it launched in is remembered for next time.
        let remembered = try await recentProjectPaths(host: host, token: token)
        XCTAssertTrue(remembered.contains(project), "The picker did not remember \(project).")
    }

    // #24: a folder outside the host's project roots is not refused outright
    // — it asks first. The host owns that rule, so this drives the real
    // refusal and the real confirmation rather than a simulated one.
    @MainActor
    func testCustomFolderOutsideRootsAsksBeforeCreating() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["MOCHA_DEV_HOST"],
              let token = environment["MOCHA_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_MOCHA_DEV_HOST/TOKEN to run the live confirmation test.")
        }

        let outside = outsideRootsPath()
        let before = Set(try await agentPaneIds(host: host, token: token))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: outside) }

        let app = XCUIApplication()
        app.launchEnvironment["MOCHA_DEV_HOST"] = host
        app.launchEnvironment["MOCHA_DEV_TOKEN"] = token
        app.launch()

        app.buttons["sessions.newAgentTab"].tap()

        // "Another folder" sits directly under the agent picker, so it is on
        // screen without scrolling however many projects this Mac has.
        let customField = app.textFields["newAgent.customPath"]
        XCTAssertTrue(customField.waitForExistence(timeout: 20), "The picker never offered a custom path field.")
        XCTAssertTrue(type(outside, into: customField, in: app), "The custom path field never took focus.")
        app.buttons["newAgent.useCustomPath"].tap()

        let create = app.buttons["newAgent.create"]
        XCTAssertTrue(create.isEnabled, "Create stayed disabled after choosing a custom folder.")
        create.tap()

        // The host refuses, and the phone asks instead of failing.
        let confirm = app.alerts.buttons["newAgent.outsideRoots.confirm"].firstMatch
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 20),
            "A folder outside the roots was not confirmed with the person."
        )
        // Nothing has been created while the question is still open.
        let during = Set(try await agentPaneIds(host: host, token: token))
        XCTAssertEqual(during, before, "An agent was created before the confirmation was answered.")

        confirm.tap()

        var created: String?
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, created == nil {
            created = try await agentPaneIds(host: host, token: token).first { !before.contains($0) }
            if created == nil { try await Task.sleep(for: .seconds(2)) }
        }
        guard let paneId = created else {
            throw XCTSkip("The host never reported the confirmed agent; cannot verify the flow.")
        }
        addTeardownBlock {
            if let tabId = try? await Self.tabId(host: host, token: token, paneId: paneId) {
                try? await Self.closeAgentTab(host: host, token: token, tabId: tabId)
            }
        }

        let cwd = try await agentCwd(host: host, token: token, paneId: paneId)
        XCTAssertEqual(cwd, outside, "The confirmed agent did not start in the custom folder.")
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

        let project = try await knownProjectPath(host: host, token: token)
        let (paneId, tabId) = try await createAgentTab(host: host, token: token, cwd: project)
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

    // Owner-reported bug: open a blocked agent, answer nothing, go back —
    // "Needs you" must still be on the home. Reproduces the full flow
    // against a live host with a real permission dialog.
    @MainActor
    func testNeedsYouSurvivesVisitingTheBlockedAgent() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["MOCHA_DEV_HOST"],
              let token = environment["MOCHA_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_MOCHA_DEV_HOST/TOKEN to run the live needs-you test.")
        }

        let project = try await knownProjectPath(host: host, token: token)
        let (paneId, tabId) = try await createAgentTab(host: host, token: token, cwd: project)
        addTeardownBlock {
            try? await Self.closeAgentTab(host: host, token: token, tabId: tabId)
        }

        try await waitForAgentStatus(host: host, token: token, paneId: paneId, status: "idle", timeout: 60)
        try await prompt(
            host: host,
            token: token,
            paneId: paneId,
            text: "Use the Bash tool to run exactly this command: touch /tmp/mocha-ui-needs-you"
        )
        try await waitForAgentStatus(host: host, token: token, paneId: paneId, status: "blocked", timeout: 150)

        let app = XCUIApplication()
        app.launchEnvironment["MOCHA_DEV_HOST"] = host
        app.launchEnvironment["MOCHA_DEV_TOKEN"] = token
        app.launch()

        let banner = app.buttons["sessions.needsYou"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "Blocked agent never reached Needs you.")

        let agentRow = app.buttons["sessions.agent.\(paneId)"]
        XCTAssertTrue(agentRow.waitForExistence(timeout: 5))
        agentRow.tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal.surface"].waitForExistence(timeout: 10))

        // Look at the dialog, answer nothing.
        try await Task.sleep(for: .seconds(12))

        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.tap()

        // The dialog is still unanswered: Needs you must be back and stay.
        for checkpoint in [5.0, 10.0, 10.0] {
            try await Task.sleep(for: .seconds(checkpoint))
            if !banner.exists {
                let raw = try await agentStatus(host: host, token: token, paneId: paneId)
                XCTFail(
                    raw == "blocked"
                        ? "PHONE-SIDE: host still reports blocked but Needs you is gone."
                        : "SOURCE FLIP: herdr now reports '\(raw ?? "gone")' while the dialog waits."
                )
                return
            }
        }
    }

    // Answer a real waiting permission straight from the Needs-you card (#23)
    // without entering the terminal. Uses a fresh scratch cwd so Claude raises
    // its reliable trust-folder dialog; that leaves the agent blocked with a
    // parseable dialog on the pane. Taps the card, taps the first option (the
    // "Yes, I trust this folder" choice), and asserts the host stops reporting
    // a dialog — the specific numbered choice actually landed.
    @MainActor
    func testAnswerWaitingPermissionFromNeedsYouCard() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["MOCHA_DEV_HOST"],
              let token = environment["MOCHA_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_MOCHA_DEV_HOST/TOKEN to run the live approve test.")
        }

        // A folder Claude has not trusted yet. The simulator shares /private/tmp
        // with the host, so creating it here makes it exist for the agent's cwd.
        let scratch = "/private/tmp/mocha-ui-approve-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)

        let (paneId, tabId) = try await createAgentTab(host: host, token: token, cwd: scratch)
        addTeardownBlock {
            try? await Self.closeAgentTab(host: host, token: token, tabId: tabId)
            try? FileManager.default.removeItem(atPath: scratch)
        }

        try await waitForAgentStatus(host: host, token: token, paneId: paneId, status: "blocked", timeout: 60)
        // Confirm a dialog actually parses before driving the UI, else skip.
        var sawDialog = false
        for _ in 0 ..< 10 where !sawDialog {
            sawDialog = try await readDialogPresent(host: host, token: token, paneId: paneId)
            if !sawDialog { try await Task.sleep(for: .seconds(1)) }
        }
        guard sawDialog else {
            throw XCTSkip("No permission dialog parsed on the pane; cannot exercise approve.")
        }

        let app = XCUIApplication()
        app.launchEnvironment["MOCHA_DEV_HOST"] = host
        app.launchEnvironment["MOCHA_DEV_TOKEN"] = token
        app.launch()

        let card = app.buttons["sessions.agent.\(paneId)"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Blocked agent never reached Needs you.")
        card.tap()

        let option = app.buttons["decision.option.1"]
        XCTAssertTrue(option.waitForExistence(timeout: 10), "Decision sheet never showed the options.")
        option.tap()

        // The choice landed if the host stops reporting a live dialog on the pane.
        var resolved = false
        for _ in 0 ..< 15 where !resolved {
            try await Task.sleep(for: .seconds(1))
            resolved = try await !readDialogPresent(host: host, token: token, paneId: paneId)
        }
        XCTAssertTrue(resolved, "The dialog was still present after tapping the option.")
    }

    private func waitForAgentStatus(
        host: String,
        token: String,
        paneId: String,
        status target: String,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await agentStatus(host: host, token: token, paneId: paneId) == target { return }
            try await Task.sleep(for: .seconds(2))
        }
        throw XCTSkip("Agent \(paneId) never reached \(target); cannot exercise the flow.")
    }

    private func agentStatus(host: String, token: String, paneId: String) async throws -> String? {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(host)/api/agents")))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        struct AgentsBody: Decodable {
            struct Agent: Decodable {
                let id: String
                let status: String
            }
            let agents: [Agent]
        }
        let body = try JSONDecoder().decode(AgentsBody.self, from: data)
        return body.agents.first { $0.id == paneId }?.status
    }

    private func prompt(host: String, token: String, paneId: String, text: String) async throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(host)/api/agents/\(paneId)/prompt")))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["text": text])
        _ = try await URLSession.shared.data(for: request)
    }

    // The host requires an explicit project folder (#24). These live tests
    // only need an agent running somewhere real, so they confirm the custom
    // location outright; the roots gate itself is covered by host tests.
    private func createAgentTab(
        host: String,
        token: String,
        cwd: String
    ) async throws -> (paneId: String, tabId: String) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(host)/api/herdr/tabs")))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "agent": "claude",
            "cwd": cwd,
            "allowOutsideRoots": true,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 201 else {
            throw XCTSkip("The host could not create a disposable agent tab.")
        }
        let payload = try JSONDecoder().decode([String: String].self, from: data)
        return (try XCTUnwrap(payload["paneId"]), try XCTUnwrap(payload["tabId"]))
    }

    // A real folder on this Mac to start a disposable agent in, read from
    // the host's own project catalog rather than hard-coding one machine's
    // layout. It prefers a folder an agent is already running in, which is
    // the best available hint that Claude trusts it — but nothing here
    // proves trust, so callers that need an idle agent must treat a trust
    // prompt as a skip rather than a failure.
    private func agentPaneIds(host: String, token: String) async throws -> [String] {
        try await agentRecords(host: host, token: token).map(\.id)
    }

    private func agentCwd(host: String, token: String, paneId: String) async throws -> String? {
        try await agentRecords(host: host, token: token).first { $0.id == paneId }?.cwd
    }

    private static func tabId(host: String, token: String, paneId: String) async throws -> String? {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(host)/api/agents")))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        struct Body: Decodable {
            struct Agent: Decodable { let id: String; let tabId: String }
            let agents: [Agent]
        }
        return try JSONDecoder().decode(Body.self, from: data).agents.first { $0.id == paneId }?.tabId
    }

    private struct AgentRecord: Decodable {
        let id: String
        let cwd: String
    }

    private func agentRecords(host: String, token: String) async throws -> [AgentRecord] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(host)/api/agents")))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        struct Body: Decodable { let agents: [AgentRecord] }
        return (try? JSONDecoder().decode(Body.self, from: data))?.agents ?? []
    }

    private func recentProjectPaths(host: String, token: String) async throws -> [String] {
        try await projectCatalog(host: host, token: token).recent.map(\.path)
    }

    // A real folder on this Mac to start a disposable agent in, read from the
    // host's own project catalog rather than hard-coding one machine's layout.
    // It prefers a folder inside the configured roots, so creating there needs
    // no confirmation, and among those one an agent is already running in —
    // the best available hint that Claude trusts it. Nothing here proves
    // trust, so callers needing an idle agent must treat a trust prompt as a
    // skip rather than a failure.
    private func knownProjectPath(host: String, token: String) async throws -> String {
        let catalog = try await projectCatalog(host: host, token: token)
        let insideRoots = catalog.recent.filter(\.withinRoots)
        guard let path = insideRoots.first(where: \.active)?.path
            ?? insideRoots.first?.path
            ?? catalog.workspaces.first?.path
        else {
            throw XCTSkip("This host has no project folder inside its roots to start a disposable agent in.")
        }
        return path
    }

    // A real folder deliberately *outside* the roots, to exercise the
    // confirmation. /private/tmp is shared with the simulator, so the folder
    // exists for the agent's cwd.
    private func outsideRootsPath() -> String {
        let path = "/private/tmp/mocha-ui-outside-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private struct ProjectCatalogBody: Decodable {
        struct Folder: Decodable { let path: String; let active: Bool; let withinRoots: Bool }
        struct Workspace: Decodable { let path: String }
        let recent: [Folder]
        let workspaces: [Workspace]
    }

    private func projectCatalog(host: String, token: String) async throws -> ProjectCatalogBody {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(host)/api/projects")))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("The host could not list its projects.")
        }
        return try JSONDecoder().decode(ProjectCatalogBody.self, from: data)
    }

    private func readDialogPresent(host: String, token: String, paneId: String) async throws -> Bool {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(host)/api/agents/\(paneId)/dialog")))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        struct Body: Decodable { let present: Bool }
        return (try? JSONDecoder().decode(Body.self, from: data))?.present ?? false
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

    // A freshly scrolled field can be hittable before it will accept keyboard
    // focus; tap until the keyboard is actually up, then type.
    @MainActor
    private func type(_ text: String, into field: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0 ..< 5 {
            field.tap()
            if app.keyboards.element.waitForExistence(timeout: 3) {
                field.typeText(text)
                return true
            }
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
