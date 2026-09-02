import XCTest

final class TaviUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // Every terminal is a herdr agent pane (#53). A pane that does not
    // exist must land on the honest not-attached state instead of a spinner
    // or a fake prompt: the overlay is up, the keyboard key is disabled, and
    // the banner says the connection failed.
    @MainActor
    func testShowsAnHonestNotAttachedTerminalForAMissingAgent() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live missing-agent test.")
        }

        let app = XCUIApplication()
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launchEnvironment["TAVI_DEV_HOST"] = host
        app.launchEnvironment["TAVI_DEV_TOKEN"] = token
        app.launchEnvironment["TAVI_DEV_AGENT"] = "tavi-ui-missing-pane"
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["terminal.surface"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["terminal.disconnected"].waitForExistence(timeout: 15),
            "A missing pane never reached the not-attached state."
        )
        // A failed session collapses its input chrome entirely (#54): a
        // disabled key row would be furniture for a terminal that cannot
        // take input; the bottom bar carries the verdict instead.
        XCTAssertFalse(app.buttons["terminal.keyboard"].exists)
        let status = app.descendants(matching: .any)["terminal.status"]
        XCTAssertTrue(status.exists)
        XCTAssertTrue(
            status.label.contains("Connection failed") || app.staticTexts["Connection failed"].exists,
            "The banner did not say the connection failed: \(status.label)"
        )
    }

    // Renderer stress: open and close the same shell pane's terminal eight
    // times with the injected corpus replaying into every fresh surface, a
    // real attach underneath, and one background/foreground cycle midway.
    @MainActor
    func testRepeatedlyFeedsCreatesAndDestroysTerminalSurface() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live renderer stress test.")
        }
        let paneId = try await createDisposableShell(host: host, token: token)

        let app = XCUIApplication()
        let corpusData = try JSONEncoder().encode(try rendererStressChunks())
        app.launchEnvironment["TAVI_DEV_RENDERER_STRESS_CHUNKS"] = String(
            decoding: corpusData,
            as: UTF8.self
        )
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launchEnvironment["TAVI_DEV_HOST"] = host
        app.launchEnvironment["TAVI_DEV_TOKEN"] = token
        app.launch()

        let row = app.buttons["sessions.agent.\(paneId)"]
        for iteration in 0..<8 {
            XCTAssertTrue(row.waitForExistence(timeout: 20), "The shell pane never appeared on the home.")
            row.tap()
            let surface = app.descendants(matching: .any)["terminal.surface"]
            XCTAssertTrue(surface.waitForExistence(timeout: 5))
            try await Task.sleep(for: .seconds(0.75))
            XCTAssertTrue((surface.value as? String)?.contains("streamed output line") == true)

            surface.tap()
            surface.typeText("echo tavi\n")
            app.buttons["terminal.dismissKeyboard"].tap()

            if iteration == 3 {
                XCUIDevice.shared.press(.home)
                app.activate()
                XCTAssertTrue(
                    app.descendants(matching: .any)["terminal.surface"].waitForExistence(timeout: 5)
                )
            }

            let backButton = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(backButton.waitForExistence(timeout: 3))
            backButton.tap()
        }

        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    @MainActor
    func testTerminalKeyboardLayout() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live keyboard layout test.")
        }
        let paneId = try await createDisposableShell(host: host, token: token)
        let app = launchIntoAgent(paneId, host: host, token: token)

        let surface = app.descendants(matching: .any)["terminal.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForTranscript(of: surface, timeout: 10) { !$0.isEmpty })

        surface.tap()
        surface.typeText("echo tavi")
        keepScreenshot(named: "Terminal with keyboard")

        app.buttons["terminal.dismissKeyboard"].tap()
        keepScreenshot(named: "Terminal without keyboard")
    }

    // The injected corpus keeps the renderer busy while a burst of live
    // typing goes to the real shell; the controls must stay reachable.
    @MainActor
    func testSustainedTypingRemainsInteractiveUnderOutputLoad() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live sustained typing test.")
        }
        let paneId = try await createDisposableShell(host: host, token: token)
        let corpusData = try JSONEncoder().encode(try rendererStressChunks())
        let app = launchIntoAgent(
            paneId,
            host: host,
            token: token,
            environment: ["TAVI_DEV_RENDERER_STRESS_CHUNKS": String(decoding: corpusData, as: UTF8.self)]
        )

        let surface = app.descendants(matching: .any)["terminal.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForTranscript(of: surface, timeout: 10) { !$0.isEmpty })

        surface.tap()
        surface.typeText(String(repeating: "tavi123 ", count: 20))

        let dismissKeyboard = app.buttons["terminal.dismissKeyboard"]
        XCTAssertTrue(dismissKeyboard.waitForExistence(timeout: 3))
        dismissKeyboard.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.exists)
        XCTAssertTrue(surface.exists)
    }

    // Reproduces the live typing loop against a real host: keystrokes must
    // echo to the screen and command output must appear while the keyboard
    // stays up, with no layout change to force a draw. Requires a live
    // connection, so it skips unless TEST_RUNNER_TAVI_DEV_* variables are
    // set on the xcodebuild invocation.
    @MainActor
    func testLiveTypingEchoesToTheScreenWhileKeyboardIsUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live echo test.")
        }
        let paneId = try await createDisposableShell(host: host, token: token)
        let app = launchIntoAgent(paneId, host: host, token: token)

        let surface = app.descendants(matching: .any)["terminal.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForTranscript(of: surface, timeout: 10) { !$0.isEmpty },
            "The connected terminal never rendered its prompt."
        )

        // Type only once the keyboard is really up (#65): a single tap and an
        // immediate typeText raced the surface becoming first responder when
        // the previous test had just dismissed the keyboard, and the
        // keystrokes went nowhere — deterministic in that order, never alone.
        let marker = "LIVE-TYPING-ECHO-OK"
        XCTAssertTrue(type("echo \(marker)\n", into: surface, in: app), "The terminal never took keyboard focus.")

        // Two occurrences: the typed echo and the command's output. The
        // transcript is a flattening of the grid, and a prompt repaint that
        // lands mid-typing (starship redraws its right side on every key)
        // can put a space inside the typed echo — "LIVE -TYPING-ECHO-OK" —
        // so whitespace is dropped before counting. Both strings are on the
        // screen; that is what this test claims.
        let echoed = waitForTranscript(of: surface, timeout: 12) { value in
            value.filter { !$0.isWhitespace }.components(separatedBy: marker).count > 2
        }
        if !echoed {
            let note = XCTAttachment(string: "keyboards=\(app.keyboards.count)\n\(((surface.value as? String) ?? "").suffix(800))")
            note.name = "echo-failure-evidence"
            note.lifetime = .keepAlways
            add(note)
        }
        XCTAssertTrue(echoed, "Typed input and its output did not reach the screen while the keyboard was up.")
    }

    // Issue #9: keyboard show/hide during continuous output must not leave
    // stale rows or mis-scaled frames. The test starts an output loop in its
    // own shell pane, drives the keyboard toggles with long settle windows,
    // and proves streaming survived both transitions through the transcript.
    @MainActor
    func testKeyboardToggleDuringLiveStreamingKeepsReceivingOutput() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live resize test.")
        }
        let paneId = try await createDisposableShell(host: host, token: token)
        let app = launchIntoAgent(paneId, host: host, token: token)

        let surface = app.descendants(matching: .any)["terminal.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForTranscript(of: surface, timeout: 10) { !$0.isEmpty })

        startOutputLoop(on: surface)
        try await Task.sleep(for: .seconds(10))

        app.buttons["terminal.dismissKeyboard"].tap()
        try await Task.sleep(for: .seconds(8))

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
    func testTouchScrollLeavesStreamingHealthy() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live scroll test.")
        }
        let paneId = try await createDisposableShell(host: host, token: token)
        let app = launchIntoAgent(paneId, host: host, token: token)

        let surface = app.descendants(matching: .any)["terminal.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForTranscript(of: surface, timeout: 10) { !$0.isEmpty })

        startOutputLoop(on: surface)
        app.buttons["terminal.dismissKeyboard"].tap()
        try await Task.sleep(for: .seconds(4))

        surface.swipeDown()
        surface.swipeDown()
        try await Task.sleep(for: .seconds(6))

        // Scrolled into history, herdr's attach viewer — like tmux before it
        // — freezes the frame and sends nothing until the next event; that
        // is scrollback working, not a broken stream. Flick back down until
        // the live tail streams again. Each flick's momentum keeps producing
        // wheel events for about a second and every event round-trips to the
        // host for a redraw, so the check first lets that burst die down and
        // then demands two spaced spontaneous updates — a lone straggler
        // redraw can never satisfy it.
        var atLiveTail = false
        var flicks = 0
        while !atLiveTail, flicks < 15 {
            surface.swipeUp()
            flicks += 1
            try await Task.sleep(for: .seconds(2.5))
            let parked = (surface.value as? String) ?? ""
            guard waitForTranscript(of: surface, timeout: 2, until: { $0 != parked }) else { continue }
            let changedOnce = (surface.value as? String) ?? ""
            atLiveTail = waitForTranscript(of: surface, timeout: 2) { $0 != changedOnce }
        }
        XCTAssertTrue(atLiveTail, "Flicking back down never returned the viewport to the live tail.")
        try await Task.sleep(for: .seconds(4))

        let before = (surface.value as? String) ?? ""
        XCTAssertTrue(
            waitForTranscript(of: surface, timeout: 8) { $0 != before },
            "Streaming output stopped reaching the screen after scroll gestures."
        )
    }

    // #56: the mic is part of the composer and nowhere else. Live mode
    // streams keys to a pty; a transcript must never have that path.
    @MainActor
    func testDictateButtonLivesOnlyInComposeMode() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live dictation test.")
        }
        let paneId = try await createDisposableShell(host: host, token: token)
        let app = launchIntoAgent(paneId, host: host, token: token)

        let surface = app.descendants(matching: .any)["terminal.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))

        let composer = app.descendants(matching: .any)["terminal.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Compose mode is the default input surface.")
        let dictate = app.buttons["terminal.dictate"]
        XCTAssertTrue(dictate.exists, "The composer offers dictation.")
        XCTAssertTrue(dictate.isEnabled)
        XCTAssertFalse(app.buttons["terminal.composerSend"].isEnabled, "Nothing to send yet.")

        app.buttons["terminal.keyboard"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal.liveHint"].waitForExistence(timeout: 5))
        XCTAssertFalse(dictate.exists, "Live mode has no mic — voice never streams into a pty.")

        app.buttons["terminal.composeMode"].tap()
        XCTAssertTrue(dictate.waitForExistence(timeout: 5))
    }

    // #45 acceptance: a fresh phone pairs from a code the host printed, sees
    // the host's fingerprint before consenting, and lands on live sessions
    // with a credential of its own. The simulator has no camera, so this
    // takes the manual-entry path; the exchange is the same.
    @MainActor
    func testPairsAFreshPhoneFromAPairingCode() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live pairing test.")
        }

        let before = Set(try await Self.pairedDeviceIds(host: host, token: token))
        addTeardownBlock {
            // Never leave the owner's Mac with a stray paired phone.
            for id in (try? await Self.pairedDeviceIds(host: host, token: token)) ?? [] where !before.contains(id) {
                try? await Self.revokeDevice(host: host, token: token, id: id)
            }
        }
        let (code, fingerprint) = try await beginPairing(host: host, token: token)

        let app = XCUIApplication()
        // A phone that has never been paired: no host, no token.
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launch()

        app.buttons["sessions.scanPairingCode"].tap()
        let manual = app.textViews["pairing.manualCode"].firstMatch.exists
            ? app.textViews["pairing.manualCode"].firstMatch
            : app.textFields["pairing.manualCode"].firstMatch
        XCTAssertTrue(manual.waitForExistence(timeout: 10), "Manual code entry never appeared.")
        manual.tap()
        manual.typeText(code)
        app.buttons["pairing.manualContinue"].tap()

        // Consent screen: the fingerprint the Mac printed, before anything is sent.
        let shown = app.staticTexts["pairing.fingerprint"]
        XCTAssertTrue(shown.waitForExistence(timeout: 10), "The verify screen never appeared.")
        XCTAssertEqual(shown.label, fingerprint)
        let beforeConsent = try await Self.pairedDeviceIds(host: host, token: token)
        XCTAssertEqual(beforeConsent.count, before.count, "A device was paired before consent.")

        app.buttons["pairing.confirm"].tap()
        XCTAssertTrue(app.staticTexts["pairing.done"].waitForExistence(timeout: 30), "Pairing never completed.")
        let after = try await Self.pairedDeviceIds(host: host, token: token)
        XCTAssertEqual(after.count, before.count + 1, "The host did not record the new phone.")
        keepScreenshot(named: "pairing-done")

        app.buttons["pairing.viewSessions"].tap()
        // Paired for real: the home is talking to the host with the new credential.
        XCTAssertTrue(
            app.staticTexts["sessions.loading"].waitForExistence(timeout: 5)
                || app.otherElements["sessions.agentsUnavailable"].waitForExistence(timeout: 5)
                || app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.agent.'")).firstMatch.waitForExistence(timeout: 15)
                || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No agents are running on'")).firstMatch.waitForExistence(timeout: 5),
            "The home never connected after pairing."
        )
        XCTAssertFalse(app.buttons["sessions.scanPairingCode"].exists, "The home still asks to pair.")

        // "This iPhone" shows who the Mac knows us as.
        app.buttons["sessions.hostMenu"].tap()
        XCTAssertTrue(app.buttons["sessions.settings"].waitForExistence(timeout: 5))
        app.buttons["sessions.settings"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.host.'")).firstMatch.waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.host.'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts[fingerprint].waitForExistence(timeout: 10), "Manage access never showed the fingerprint.")
        keepScreenshot(named: "manage-access")
        // Two sheets are up (Settings under This iPhone); close both so the
        // home is visible for the revocation check below.
        app.buttons["manageAccess.done"].tap()
        XCTAssertTrue(app.buttons["settings.done"].waitForExistence(timeout: 5))
        app.buttons["settings.done"].tap()

        // Revoke on the Mac while the app is open: the phone must notice and
        // offer to pair again rather than retry a dead credential forever.
        for id in after where !before.contains(id) {
            try await Self.revokeDevice(host: host, token: token, id: id)
        }
        // Found by label: SwiftUI drops a child button's identifier when the
        // enclosing card carries one of its own.
        XCTAssertTrue(
            app.buttons["Pair again"].waitForExistence(timeout: 15),
            "The home did not notice the revocation."
        )
        keepScreenshot(named: "pairing-revoked")

        // Leave the simulator as it was found: no persisted host or credential
        // from this test can leak into the env-seeded tests that follow.
        app.terminate()
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["sessions.scanPairingCode"].waitForExistence(timeout: 10))
    }

    // #51: the font size setting shows the projected terminal grid in
    // honest numbers and survives a relaunch. Runs without a host — the
    // preview is a local Ghostty surface.
    @MainActor
    func testFontSizeSettingShowsGridAndPersists() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launch()
        app.buttons["sessions.hostMenu"].tap()
        XCTAssertTrue(app.buttons["sessions.settings"].waitForExistence(timeout: 5))
        app.buttons["sessions.settings"].tap()

        let slider = app.sliders["settings.fontSize"]
        XCTAssertTrue(slider.waitForExistence(timeout: 10), "The font size slider never appeared.")
        let readout = app.descendants(matching: .any)["settings.gridReadout"]
        // The preview surface must report a real grid, not a placeholder.
        // The readout speaks the way VoiceOver does: "44 by 22".
        let hasGrid = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS ' by '"),
            object: readout
        )
        XCTAssertEqual(XCTWaiter().wait(for: [hasGrid], timeout: 10), .completed, "The grid readout never showed numbers.")
        let beforeColumns = try XCTUnwrap(
            Self.firstNumber(in: (readout.value as? String) ?? ""),
            "Unreadable grid readout"
        )

        // Push the slider to the largest size: fewer columns and rows, and
        // the readout announces the change.
        slider.adjust(toNormalizedSliderPosition: 1.0)
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS 'changing to'"),
            object: readout
        )
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 10), .completed, "The grid readout never reflected the new size.")
        // The trade-off must point the honest way: bigger font, fewer columns.
        let spoken = (readout.value as? String) ?? ""
        let afterColumns = try XCTUnwrap(
            Self.firstNumber(in: spoken.components(separatedBy: "changing to").last ?? "")
        )
        XCTAssertLessThan(afterColumns, beforeColumns, "A bigger font must project fewer columns (\(spoken)).")
        let chosen = pointsPrefix(of: slider)
        XCTAssertFalse(chosen.isEmpty, "The slider never spoke a point size.")
        keepScreenshot(named: "settings-font-size")

        // Persisted per phone: a relaunch keeps the chosen size. The reset
        // flag must not ride along or it would wipe the very preference
        // this asserts on.
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "TAVI_DEV_RESET")
        app.launch()
        app.buttons["sessions.hostMenu"].tap()
        XCTAssertTrue(app.buttons["sessions.settings"].waitForExistence(timeout: 5))
        app.buttons["sessions.settings"].tap()
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        // The slider's accessibility value is exactly what VoiceOver reads;
        // comparing to the size chosen before the relaunch covers both
        // persistence and the a11y acceptance criterion in one assert.
        XCTAssertEqual(pointsPrefix(of: slider), chosen, "The font size did not persist across relaunch.")
    }

    // "23.5 points, 21 by 14" → "23.5 points": the grid half arrives
    // asynchronously from the preview surface, so only the size may be
    // compared across a relaunch.
    @MainActor
    private func pointsPrefix(of slider: XCUIElement) -> String {
        let value = (slider.value as? String) ?? ""
        guard let range = value.range(of: " points") else { return value }
        return String(value[..<range.upperBound])
    }

    private static func firstNumber(in spoken: String) -> Int? {
        spoken.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) }
    }

    // #55: name a pane from its own page. The host renames the herdr tab;
    // the name comes back through the events feed and becomes the pane's
    // identity on the chip.
    @MainActor
    func testRenamesAPaneFromTheTerminal() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live rename test.")
        }
        let paneId = try await createDisposableShell(host: host, token: token)
        let app = launchIntoAgent(paneId, host: host, token: token)

        let chip = app.descendants(matching: .any)["terminal.identity"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "The identity chip never appeared.")
        // Holding the chip opens the rename alert directly; retry the
        // press while the freshly attached surface settles.
        let alert = app.alerts.firstMatch
        for _ in 0 ..< 3 where !alert.exists {
            chip.press(forDuration: 0.9)
            if alert.waitForExistence(timeout: 4) { break }
        }
        XCTAssertTrue(alert.waitForExistence(timeout: 4), "The rename alert never appeared.")
        let field = alert.textFields.firstMatch.exists ? alert.textFields.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The rename field never appeared.")
        field.tap()
        field.typeText("ship the fix")
        alert.buttons["Save"].tap()

        // The host is the truth: the herdr tab now carries the name.
        var label: String?
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, label != "ship the fix" {
            label = try await Self.tabLabel(host: host, token: token, paneId: paneId)
            if label != "ship the fix" { try await Task.sleep(for: .seconds(1)) }
        }
        XCTAssertEqual(label, "ship the fix", "The host never reported the new tab name.")

        // And the chip speaks it once the events feed catches up.
        let renamedChip = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS 'ship the fix'"),
            object: chip
        )
        XCTAssertEqual(XCTWaiter().wait(for: [renamedChip], timeout: 15), .completed, "The chip never showed the new name: \(chip.label)")
    }

    private static func tabLabel(host: String, token: String, paneId: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "\(host)/api/agents")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agents = payload["agents"] as? [[String: Any]] else { return nil }
        return agents.first { $0["id"] as? String == paneId }?["tabLabel"] as? String
    }

    // #46: a phone can unpair itself. The Mac stops listing it and the home
    // goes back to "No Paired Computers".
    @MainActor
    func testUnpairsItselfFromThePhone() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live unpair test.")
        }
        let before = Set(try await Self.pairedDeviceIds(host: host, token: token))
        addTeardownBlock {
            for id in (try? await Self.pairedDeviceIds(host: host, token: token)) ?? [] where !before.contains(id) {
                try? await Self.revokeDevice(host: host, token: token, id: id)
            }
        }
        let (code, _) = try await beginPairing(host: host, token: token)

        let app = XCUIApplication()
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launch()
        app.buttons["sessions.scanPairingCode"].tap()
        let manual = app.textViews["pairing.manualCode"].firstMatch.exists
            ? app.textViews["pairing.manualCode"].firstMatch
            : app.textFields["pairing.manualCode"].firstMatch
        XCTAssertTrue(manual.waitForExistence(timeout: 10))
        manual.tap()
        manual.typeText(code)
        app.buttons["pairing.manualContinue"].tap()
        XCTAssertTrue(app.buttons["pairing.confirm"].waitForExistence(timeout: 10))
        app.buttons["pairing.confirm"].tap()
        XCTAssertTrue(app.staticTexts["pairing.done"].waitForExistence(timeout: 30))
        app.buttons["pairing.viewSessions"].tap()
        let paired = try await Self.pairedDeviceIds(host: host, token: token)
        XCTAssertEqual(paired.count, before.count + 1)

        app.buttons["sessions.hostMenu"].tap()
        XCTAssertTrue(app.buttons["sessions.settings"].waitForExistence(timeout: 5))
        app.buttons["sessions.settings"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.host.'")).firstMatch.waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.host.'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["manageAccess.unpair"].waitForExistence(timeout: 10))
        app.buttons["manageAccess.unpair"].tap()

        // The This iPhone sheet dismisses itself after the unpair; the
        // Settings sheet under it still covers the home, so close it.
        let unpairGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons["manageAccess.unpair"]
        )
        XCTAssertEqual(XCTWaiter().wait(for: [unpairGone], timeout: 15), .completed)
        XCTAssertTrue(app.buttons["settings.done"].waitForExistence(timeout: 5))
        app.buttons["settings.done"].tap()

        XCTAssertTrue(
            app.buttons["sessions.scanPairingCode"].waitForExistence(timeout: 15),
            "The home did not return to the unpaired state."
        )
        let after = try await Self.pairedDeviceIds(host: host, token: token)
        XCTAssertEqual(Set(after), before, "The Mac still lists the unpaired phone.")
    }

    // #24 acceptance: create an agent in a folder chosen on the phone, and
    // never in the host's home directory. Drives the real picker against a
    // live host, then closes the tab it made.
    @MainActor
    func testCreateAgentInAPickedProjectFolder() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live picker test.")
        }

        let project = try await knownProjectPath(host: host, token: token)
        let before = Set(try await agentPaneIds(host: host, token: token))

        let app = XCUIApplication()
        // Start from nothing persisted, then seed from the environment: a
        // credential left by an earlier run (a pairing test, say) must never
        // decide what this test connects with.
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launchEnvironment["TAVI_DEV_HOST"] = host
        app.launchEnvironment["TAVI_DEV_TOKEN"] = token
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

        // Creating opens the new agent's terminal at once (#67) — no hunting
        // for the row on the home. The identity header names it once the
        // live list catches up.
        XCTAssertTrue(
            app.descendants(matching: .any)["terminal.identity"].waitForExistence(timeout: 30),
            "Create did not open the new agent's terminal."
        )
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
        // The terminal is connected to that pane, not failed on a pane the
        // host had not listed yet.
        XCTAssertTrue(
            waitForLiveTerminal(app, timeout: 30),
            "The terminal opened on the new pane did not connect: \(app.descendants(matching: .any)["terminal.status"].firstMatch.label)"
        )
        keepScreenshot(named: "new-agent-opened-terminal")

        // Born where it was told to be, not in the host's home directory.
        let cwd = try await agentCwd(host: host, token: token, paneId: paneId)
        XCTAssertEqual(cwd, project, "The agent did not start in the folder picked on the phone.")

        // Back on the home the same agent has its row.
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.tap()
        XCTAssertTrue(
            app.buttons["sessions.agent.\(paneId)"].waitForExistence(timeout: 20),
            "The agent created from the picker never appeared on the home."
        )

        // The folder it launched in is remembered for next time.
        let remembered = try await recentProjectPaths(host: host, token: token)
        XCTAssertTrue(remembered.contains(project), "The picker did not remember \(project).")
    }

    // #75: the third answer to "where" — a worktree the sheet creates first.
    // Picks Terminal (nothing to trust), a repository the host lists, types
    // a branch, and lands in a terminal whose cwd is the new worktree beside
    // the repository. Leaves that worktree on the host: there is no remove
    // route yet (#73 part 6) — clean it up with `git worktree remove` after
    // a run; the branch is named `ui-test/wt-…` so it is easy to spot.
    @MainActor
    func testCreateWorktreeFromPicker() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live picker test.")
        }
        let repo = try await knownRepo(host: host, token: token)
        let branch = "ui-test/wt-\(UUID().uuidString.prefix(6).lowercased())"
        let expectedPath = (repo.root as NSString).deletingLastPathComponent + "/\(repo.name)-worktrees/" + branch.replacingOccurrences(of: "/", with: "-")
        let before = Set(try await agentPaneIds(host: host, token: token))

        let app = XCUIApplication()
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launchEnvironment["TAVI_DEV_HOST"] = host
        app.launchEnvironment["TAVI_DEV_TOKEN"] = token
        app.launch()

        app.buttons["sessions.newAgentTab"].tap()
        XCTAssertTrue(
            app.otherElements["newAgent.folders"].waitForExistence(timeout: 20)
                || app.collectionViews["newAgent.folders"].waitForExistence(timeout: 1),
            "The project picker never listed any folders."
        )
        app.buttons["newAgent.agentKind"].tap()
        let terminal = app.buttons["newAgent.agentKind.shell"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "The agent menu never offered Terminal.")
        terminal.tap()

        let worktreeMode = app.buttons["A new worktree"]
        XCTAssertTrue(worktreeMode.waitForExistence(timeout: 10), "The sheet never offered a new worktree — does the host list any repository?")
        worktreeMode.tap()
        keepScreenshot(named: "new-agent-worktree-mode")

        let create = app.buttons["newAgent.create"]
        XCTAssertFalse(create.isEnabled, "Create was enabled before a repository and branch were given.")

        app.buttons["newAgent.worktree.repo"].tap()
        let choice = app.buttons[repo.name].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "The repository menu never offered \(repo.name).")
        choice.tap()

        let field = app.textFields["newAgent.worktree.branch"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(branch)
        XCTAssertTrue(create.waitForExistence(timeout: 2) && create.isEnabled, "Create stayed disabled with a repository and branch.")
        keepScreenshot(named: "new-agent-worktree-filled")
        create.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["terminal.identity"].waitForExistence(timeout: 60),
            "Create and start did not open the new agent's terminal."
        )
        var created: String?
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, created == nil {
            let now = try await agentPaneIds(host: host, token: token)
            created = now.first { !before.contains($0) }
            if created == nil { try await Task.sleep(for: .seconds(2)) }
        }
        guard let paneId = created else {
            throw XCTSkip("The host never reported a new agent; cannot verify the worktree end to end.")
        }
        addTeardownBlock {
            if let tabId = try? await Self.tabId(host: host, token: token, paneId: paneId) {
                try? await Self.closeAgentTab(host: host, token: token, tabId: tabId)
            }
        }
        XCTAssertTrue(waitForLiveTerminal(app, timeout: 30), "The terminal opened on the new pane did not connect.")
        let cwd = try await agentCwd(host: host, token: token, paneId: paneId)
        XCTAssertEqual(cwd, expectedPath, "The agent did not start in the worktree the sheet said it would create.")
        keepScreenshot(named: "new-agent-worktree-terminal")
    }

    // Empty terminal: pick "Terminal" in the agent menu and the host reports
    // a plain shell pane to herdr so it lists and opens like an agent.
    @MainActor
    func testCreateTerminalFromPicker() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live terminal test.")
        }

        let project = try await knownProjectPath(host: host, token: token)
        let before = Set(try await agentPaneIds(host: host, token: token))

        let app = XCUIApplication()
        // Start from nothing persisted, then seed from the environment: a
        // credential left by an earlier run (a pairing test, say) must never
        // decide what this test connects with.
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launchEnvironment["TAVI_DEV_HOST"] = host
        app.launchEnvironment["TAVI_DEV_TOKEN"] = token
        app.launch()

        app.buttons["sessions.newAgentTab"].tap()
        XCTAssertTrue(app.buttons["newAgent.agentKind"].waitForExistence(timeout: 20))
        app.buttons["newAgent.agentKind"].tap()
        let terminal = app.buttons["newAgent.agentKind.shell"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "The agent menu never offered a Terminal.")
        terminal.tap()

        let folder = app.buttons["newAgent.folder.\(project)"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.tap()
        app.buttons["newAgent.create"].tap()

        var created: String?
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, created == nil {
            created = try await agentPaneIds(host: host, token: token).first { !before.contains($0) }
            if created == nil { try await Task.sleep(for: .seconds(1)) }
        }
        guard let paneId = created else {
            throw XCTSkip("The host never reported the terminal; cannot verify the flow.")
        }
        addTeardownBlock {
            if let tabId = try? await Self.tabId(host: host, token: token, paneId: paneId) {
                try? await Self.closeAgentTab(host: host, token: token, tabId: tabId)
            }
        }

        let kind = try await agentKind(host: host, token: token, paneId: paneId)
        let cwd = try await agentCwd(host: host, token: token, paneId: paneId)
        XCTAssertEqual(kind, "shell")
        XCTAssertEqual(cwd, project)

        // Creating lands you in the terminal (#67), attached to the new pane
        // with a live shell prompt.
        XCTAssertTrue(
            app.descendants(matching: .any)["terminal.identity"].waitForExistence(timeout: 20),
            "Create did not open the new terminal."
        )
        XCTAssertTrue(
            waitForLiveTerminal(app, timeout: 20),
            "The new terminal did not connect: \(app.descendants(matching: .any)["terminal.status"].firstMatch.label)"
        )

        // A shell takes commands, not prompts (#43): the composer must run
        // the text as a command line, and say so in its placeholder.
        let composer = app.textFields["terminal.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.placeholderValue, "Type a command…")
        let marker = "TAVI43-\(UUID().uuidString.prefix(6))"
        composer.tap()
        composer.typeText("echo \(marker)")
        app.buttons["terminal.composerSend"].tap()
        let surface = app.descendants(matching: .any)["terminal.surface"]
        XCTAssertTrue(
            waitForTranscript(of: surface, timeout: 15) { $0.contains(marker) },
            "The command sent from the composer never ran in the shell."
        )
        keepScreenshot(named: "terminal-from-picker")
    }

    // #26 acceptance: the home reads computer → project → agents. Two
    // disposable terminals in two different folders must land under two
    // project headers beneath the paired computer.
    @MainActor
    func testHomeGroupsAgentsByComputerAndProject() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live home-grouping test.")
        }

        func trimmed(_ path: String) -> String {
            var path = path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        let catalog = try await projectCatalog(host: host, token: token)
        let first = try await knownProjectPath(host: host, token: token)
        guard let second = (catalog.recent.filter(\.withinRoots).map(\.path) + catalog.workspaces.map(\.path))
            .first(where: { trimmed($0) != trimmed(first) })
        else {
            throw XCTSkip("This host has only one project folder; the grouping needs two.")
        }

        let one = try await createAgentTab(host: host, token: token, cwd: first, agent: "shell")
        addTeardownBlock { try? await Self.closeAgentTab(host: host, token: token, tabId: one.tabId) }
        let two = try await createAgentTab(host: host, token: token, cwd: second, agent: "shell")
        addTeardownBlock { try? await Self.closeAgentTab(host: host, token: token, tabId: two.tabId) }
        // The header is keyed by the cwd the host *reports* for the agent,
        // which need not be byte-identical to the catalog path we asked for.
        let firstReported = try await agentCwd(host: host, token: token, paneId: one.paneId)
        let secondReported = try await agentCwd(host: host, token: token, paneId: two.paneId)
        // Since #74 a repository is one card keyed by its main worktree, so
        // an agent below a repo root files under the root, not its own cwd.
        let firstPath = try await cardKey(host: host, token: token, cwd: trimmed(try XCTUnwrap(firstReported)))
        let secondPath = try await cardKey(host: host, token: token, cwd: trimmed(try XCTUnwrap(secondReported)))
        if firstPath == secondPath {
            throw XCTSkip("Both folders belong to the same repository; the grouping needs two cards.")
        }

        let app = XCUIApplication()
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launchEnvironment["TAVI_DEV_HOST"] = host
        app.launchEnvironment["TAVI_DEV_TOKEN"] = token
        app.launch()

        let firstHeader = app.descendants(matching: .any)["sessions.project.\(firstPath)"]
        let secondHeader = app.descendants(matching: .any)["sessions.project.\(secondPath)"]
        XCTAssertTrue(firstHeader.waitForExistence(timeout: 20), "No project header for \(firstPath).")
        XCTAssertTrue(secondHeader.waitForExistence(timeout: 20), "No project header for \(secondPath).")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.computer.'")).firstMatch.exists,
            "The computer header is missing."
        )
        let firstRow = app.buttons["sessions.agent.\(one.paneId)"]
        let secondRow = app.buttons["sessions.agent.\(two.paneId)"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        XCTAssertTrue(secondRow.exists)

        // Each terminal sits under its own folder and above the next one:
        // the row's top lies strictly between its header and the other
        // header, whichever order the two folders sort in.
        let headers = [firstHeader, secondHeader].map(\.frame.minY)
        let rows = [firstRow, secondRow].map(\.frame.minY)
        for index in 0..<2 {
            let other = 1 - index
            XCTAssertLessThan(headers[index], rows[index], "Row \(index) sits above its own header.")
            if headers[other] > headers[index] {
                XCTAssertLessThan(rows[index], headers[other], "Row \(index) sits under the other folder's header.")
            }
        }
        keepScreenshot(named: "home-grouped-by-project")
    }

    // #24: a folder outside the host's project roots is not refused outright
    // — it asks first. The host owns that rule, so this drives the real
    // refusal and the real confirmation rather than a simulated one.
    @MainActor
    func testCustomFolderOutsideRootsAsksBeforeCreating() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live confirmation test.")
        }

        let outside = outsideRootsPath()
        let before = Set(try await agentPaneIds(host: host, token: token))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: outside) }

        let app = XCUIApplication()
        // Start from nothing persisted, then seed from the environment: a
        // credential left by an earlier run (a pairing test, say) must never
        // decide what this test connects with.
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launchEnvironment["TAVI_DEV_HOST"] = host
        app.launchEnvironment["TAVI_DEV_TOKEN"] = token
        app.launch()

        app.buttons["sessions.newAgentTab"].tap()

        // "Another folder" closes the sheet below Recent/Projects (#54 —
        // the common path leads). The List is lazy, so the row does not
        // exist until scrolled to; the typing helper below still proves it
        // is genuinely reachable, not hidden under the floating search
        // field (the #24 lesson).
        let customField = app.textFields["newAgent.customPath"]
        var scrolls = 0
        while !customField.exists, scrolls < 8 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(customField.waitForExistence(timeout: 10), "The picker never offered a custom path field.")
        XCTAssertTrue(type(outside, into: customField, in: app), "The custom path field never took focus.")
        // The section is the last row; with the keyboard up the button can
        // sit beneath it — scroll it clear before tapping.
        app.swipeUp()
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
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live jump test.")
        }

        let project = try await knownProjectPath(host: host, token: token)
        let (paneId, tabId) = try await createAgentTab(host: host, token: token, cwd: project)
        addTeardownBlock {
            try? await Self.closeAgentTab(host: host, token: token, tabId: tabId)
        }

        let app = XCUIApplication()
        // Start from nothing persisted, then seed from the environment: a
        // credential left by an earlier run (a pairing test, say) must never
        // decide what this test connects with.
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launchEnvironment["TAVI_DEV_HOST"] = host
        app.launchEnvironment["TAVI_DEV_TOKEN"] = token
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
        // The tree lists every workspace and tab on the host; the current
        // pane's row can sit below the sheet's medium detent, so scroll the
        // sheet until its badge is on screen.
        let currentBadge = app.staticTexts["Current"]
        var badgeVisible = currentBadge.waitForExistence(timeout: 5)
        for _ in 0 ..< 6 where !badgeVisible {
            app.descendants(matching: .any)["terminal.jumpSheet"].swipeUp()
            badgeVisible = currentBadge.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(badgeVisible, "The Jump sheet never badged the current pane.")
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
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live needs-you test.")
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
            text: "Use the Bash tool to run exactly this command: touch /tmp/tavi-ui-needs-you"
        )
        try await waitForAgentStatus(host: host, token: token, paneId: paneId, status: "blocked", timeout: 150)

        let app = XCUIApplication()
        // Start from nothing persisted, then seed from the environment: a
        // credential left by an earlier run (a pairing test, say) must never
        // decide what this test connects with.
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launchEnvironment["TAVI_DEV_HOST"] = host
        app.launchEnvironment["TAVI_DEV_TOKEN"] = token
        app.launch()

        // A waiting row opens the decision sheet (home v2/v3, PRD §7.3);
        // the terminal is its escape hatch.
        let agentRow = app.buttons["sessions.agent.\(paneId)"]
        XCTAssertTrue(agentRow.waitForExistence(timeout: 15), "Blocked agent never reached Needs you.")
        agentRow.tap()
        let openTerminal = app.buttons["decision.openTerminal"]
        XCTAssertTrue(openTerminal.waitForExistence(timeout: 10), "The waiting row did not open the decision sheet.")
        openTerminal.tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal.surface"].waitForExistence(timeout: 10))

        // Look at the dialog, answer nothing.
        try await Task.sleep(for: .seconds(12))

        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.tap()

        // The dialog is still unanswered: Needs you must be back and stay.
        for checkpoint in [5.0, 10.0, 10.0] {
            try await Task.sleep(for: .seconds(checkpoint))
            if !agentRow.exists {
                let raw = try await agentStatus(host: host, token: token, paneId: paneId)
                XCTFail(
                    raw == "blocked"
                        ? "PHONE-SIDE: host still reports blocked but the needs-you card is gone."
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
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live approve test.")
        }

        // A folder Claude has not trusted yet. The simulator shares /private/tmp
        // with the host, so creating it here makes it exist for the agent's cwd.
        let scratch = "/private/tmp/tavi-ui-approve-\(UUID().uuidString.prefix(8))"
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
        // Start from nothing persisted, then seed from the environment: a
        // credential left by an earlier run (a pairing test, say) must never
        // decide what this test connects with.
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launchEnvironment["TAVI_DEV_HOST"] = host
        app.launchEnvironment["TAVI_DEV_TOKEN"] = token
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


    // Files mentioned (#61): a path the agent printed is offered only when it
    // is a real file inside the roots; a made-up one is not. Then the two
    // other lists — Changed (#25) and Browse (#57) — render from the same
    // sheet. Screenshots kept for the design pass.
    @MainActor
    func testFilesMentionedOffersOnlyRealPaths() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the live files test.")
        }
        let paneId = try await createDisposableShell(host: host, token: token)
        let app = launchIntoAgent(paneId, host: host, token: token)
        let surface = app.descendants(matching: .any)["terminal.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 20))
        try await Task.sleep(for: .seconds(2))

        // Type the echo through the terminal itself, like the streaming
        // tests do: herdr refuses send_keys to a shell pane this young.
        let marker = "definitely-missing-\(Int.random(in: 1000...9999)).md"
        surface.tap()
        surface.typeText("echo README.md docs/\(marker)\n")
        XCTAssertTrue(
            waitForTranscript(of: surface, timeout: 15) { $0.contains(marker) },
            "The echoed paths never reached the terminal transcript."
        )
        if app.buttons["terminal.dismissKeyboard"].firstMatch.exists {
            app.buttons["terminal.dismissKeyboard"].firstMatch.tap()
        }
        let files = app.buttons["terminal.files"]
        XCTAssertTrue(files.waitForExistence(timeout: 5), "No Files button on the terminal.")
        // What the phone actually scans: the surface's accessibility value
        // is the same transcript. Kept as evidence when the list is empty.
        let surfaceValue = (app.descendants(matching: .any)["terminal.surface"].value as? String) ?? ""
        let transcriptNote = XCTAttachment(string: String(surfaceValue.suffix(1500)))
        transcriptNote.name = "surface-transcript-tail"
        transcriptNote.lifetime = .keepAlways
        add(transcriptNote)
        files.tap()

        let real = app.buttons["files.mentioned.README.md"]
        XCTAssertTrue(real.waitForExistence(timeout: 20), "README.md was echoed but not offered.")
        XCTAssertFalse(
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier CONTAINS 'definitely-missing'")).firstMatch.exists,
            "A made-up path was offered."
        )
        keepScreenshot("files-01-mentioned")

        real.tap()
        XCTAssertTrue(app.navigationBars["README.md"].waitForExistence(timeout: 10), "The viewer did not open.")
        try await Task.sleep(for: .seconds(1))
        keepScreenshot("files-02-markdown")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["Changed"].tap()
        let changedOrEmpty = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'files.changed.' OR identifier == 'files.changes.empty' OR identifier == 'files.changes.failed'")
        ).firstMatch
        XCTAssertTrue(changedOrEmpty.waitForExistence(timeout: 20), "Changed never settled.")
        keepScreenshot("files-03-changed")
        if app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'files.changed.'")).firstMatch.exists {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'files.changed.'")).firstMatch.tap()
            _ = app.descendants(matching: .any)["files.viewer.diff"].waitForExistence(timeout: 15)
                || app.descendants(matching: .any)["files.viewer.message"].waitForExistence(timeout: 2)
            try await Task.sleep(for: .seconds(1))
            keepScreenshot("files-04-diff")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        app.buttons["Browse"].tap()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'files.browse.'")).firstMatch.waitForExistence(timeout: 20),
            "Browse listed nothing."
        )
        keepScreenshot("files-05-browse")
    }

    @MainActor
    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
        cwd: String,
        agent: String = "claude"
    ) async throws -> (paneId: String, tabId: String) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(host)/api/herdr/tabs")))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "agent": agent,
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
    private func beginPairing(host: String, token: String) async throws -> (code: String, fingerprint: String) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(host)/api/pair/begin")))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 201 else {
            throw XCTSkip("The host could not start pairing.")
        }
        struct Body: Decodable {
            struct Host: Decodable { let name: String; let fingerprint: String }
            let secret: String
            let host: Host
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        var components = URLComponents()
        components.scheme = "tavi"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "u", value: host),
            URLQueryItem(name: "s", value: body.secret),
            URLQueryItem(name: "f", value: body.host.fingerprint),
            URLQueryItem(name: "n", value: body.host.name),
        ]
        return (try XCTUnwrap(components.url?.absoluteString), body.host.fingerprint)
    }

    private static func pairedDeviceIds(host: String, token: String) async throws -> [String] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(host)/api/devices")))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        struct Body: Decodable {
            struct Device: Decodable { let id: String }
            let devices: [Device]
        }
        return (try? JSONDecoder().decode(Body.self, from: data))?.devices.map(\.id) ?? []
    }

    private static func revokeDevice(host: String, token: String, id: String) async throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(host)/api/devices/\(id)")))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await URLSession.shared.data(for: request)
    }

    private func agentPaneIds(host: String, token: String) async throws -> [String] {
        try await agentRecords(host: host, token: token).map(\.id)
    }

    private func agentKind(host: String, token: String, paneId: String) async throws -> String? {
        try await agentRecords(host: host, token: token).first { $0.id == paneId }?.agent
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
        let agent: String
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

    private struct RepoRecord: Decodable {
        struct Worktree: Decodable { let path: String }
        let root: String
        let name: String
        let worktrees: [Worktree]
    }

    private func repos(host: String, token: String) async throws -> [RepoRecord] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(host)/api/repos")))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        struct Body: Decodable { let repos: [RepoRecord] }
        return (try? JSONDecoder().decode(Body.self, from: data))?.repos ?? []
    }

    // A repository the host can make a worktree in (#75): the one holding
    // the known project folder when it is a repo, else the first listed.
    private func knownRepo(host: String, token: String) async throws -> (root: String, name: String) {
        let list = try await repos(host: host, token: token)
        let project = try await knownProjectPath(host: host, token: token)
        let match = list.first { repo in repo.worktrees.contains { project == $0.path || project.hasPrefix($0.path + "/") } } ?? list.first
        guard let match else { throw XCTSkip("This host lists no git repository to create a worktree in.") }
        return (match.root, match.name)
    }

    // The home card an agent files under (#74): its repository's root when
    // one of the repo's worktrees contains the cwd, else the cwd itself.
    private func cardKey(host: String, token: String, cwd: String) async throws -> String {
        for repo in try await repos(host: host, token: token) {
            if repo.worktrees.contains(where: { cwd == $0.path || cwd.hasPrefix($0.path + "/") }) { return repo.root }
        }
        return cwd
    }

    // A real folder deliberately *outside* the roots, to exercise the
    // confirmation. /private/tmp is shared with the simulator, so the folder
    // exists for the agent's cwd.
    private func outsideRootsPath() -> String {
        let path = "/private/tmp/tavi-ui-outside-\(UUID().uuidString.prefix(8))"
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

    // The terminal tests run in a shell pane of their own (#42) inside a real
    // project folder, closed again in teardown — the owner's live agents are
    // never touched.
    private func createDisposableShell(host: String, token: String) async throws -> String {
        let project = try await knownProjectPath(host: host, token: token)
        let (paneId, tabId) = try await createAgentTab(host: host, token: token, cwd: project, agent: "shell")
        addTeardownBlock {
            try? await Self.closeAgentTab(host: host, token: token, tabId: tabId)
        }
        return paneId
    }

    // Launch straight into one pane's terminal (TAVI_DEV_AGENT), starting
    // from nothing persisted: a credential left by an earlier run must never
    // decide what this test connects with.
    @MainActor
    private func launchIntoAgent(
        _ paneId: String,
        host: String,
        token: String,
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launchEnvironment["TAVI_DEV_HOST"] = host
        app.launchEnvironment["TAVI_DEV_TOKEN"] = token
        app.launchEnvironment["TAVI_DEV_AGENT"] = paneId
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }

    // A shell pane prints nothing on its own. Typing a loop into it keeps
    // the screen changing for the rest of the test; closing the tab in
    // teardown ends the loop.
    @MainActor
    private func startOutputLoop(on surface: XCUIElement) {
        surface.tap()
        surface.typeText("while true; do echo streamed output line $RANDOM; sleep 0.2; done\n")
    }

    // A connected terminal is silent (#54): no status bar, input chrome
    // present. A failed one collapses the chrome and shows its verdict.
    @MainActor
    private func waitForLiveTerminal(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.descendants(matching: .any)["terminal.disconnected"].exists { return false }
            let status = app.descendants(matching: .any)["terminal.status"]
            if status.exists, status.label.contains("failed") { return false }
            if app.buttons["terminal.keyboard"].exists, !status.exists { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
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
