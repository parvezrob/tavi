import XCTest

// Memory checks for the two screens a person keeps open for hours: the
// dev-server preview (#58) and the terminal. They run against the live host
// on the simulator only when asked (`TEST_RUNNER_TAVI_MEMORY=1`), because
// each one takes minutes and the owner's Mac is the host.
//
// Two kinds of check:
//   * open/close cycles under `XCTMemoryMetric` — 5 measured iterations of
//     40 cycles each = 200 cycles; a leak per cycle shows up as a steadily
//     positive "Memory Physical" delta and a rising peak;
//   * a long stay (`TEST_RUNNER_TAVI_MEMORY_SOAK_MINUTES`) with the screen
//     doing real work, while `scripts/memsample.sh` outside samples the app's
//     footprint and runs `leaks` when the test writes its sync marker.
final class TaviMemoryChecks: XCTestCase {
    private let cyclesPerIteration = 40

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Preview sheet

    @MainActor
    func testPreviewSheetOpenCloseCycles() async throws {
        let live = try liveEnvironment()
        let app = try await launchIntoPreviewShell(live)
        // First open carries the consent card (once per launch).
        openPreview(app, expectConsent: true)
        closePreview(app)

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTMemoryMetric(application: app), XCTClockMetric()], options: options) {
            for _ in 0..<cyclesPerIteration {
                openPreview(app, expectConsent: false)
                closePreview(app)
            }
        }
        // Leave the sheet closed and hold still so `leaks` can look.
        try await leaksWindow(live, label: "preview-cycles")
    }

    @MainActor
    func testPreviewStaysOpen() async throws {
        let live = try liveEnvironment()
        let minutes = try soakMinutes()
        let app = try await launchIntoPreviewShell(live)
        openPreview(app, expectConsent: true)

        // Real work while it sits there: an edit on the computer every two
        // minutes must reach the phone through the door's WebSocket, exactly
        // as an agent's edits would during a long session.
        let mainFile = URL(fileURLWithPath: "\(live.previewCwd)/src/main.js")
        let original = try String(contentsOf: mainFile, encoding: .utf8)
        addTeardownBlock { try? original.write(to: mainFile, atomically: true, encoding: .utf8) }
        let web = app.descendants(matching: .any)["preview.web"]
        let banner = app.descendants(matching: .any)["preview.banner"]
        let deadline = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        var edits = 0
        var minute = 0
        while Date() < deadline {
            try await Task.sleep(for: .seconds(60))
            minute += 1
            XCTAssertTrue(web.exists, "The preview page went away while it was supposed to stay open.")
            XCTAssertFalse(banner.exists, "The preview shows a problem banner: \(banner.label)")
            if original.contains("Get started"), minute.isMultiple(of: 2) {
                edits += 1
                let marker = "Soak edit \(edits)"
                try original.replacingOccurrences(of: "Get started", with: marker).write(to: mainFile, atomically: true, encoding: .utf8)
                let reloaded = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
                XCTAssertTrue(reloaded.waitForExistence(timeout: 20), "Edit \(edits) did not reach the phone through the door.")
            }
        }
        try await leaksWindow(live, label: "preview-stay")
        closePreview(app)
    }

    // MARK: - Terminal screen

    @MainActor
    func testTerminalOpenCloseCycles() async throws {
        let live = try liveEnvironment()
        let paneId = try await createShell(live, cwd: live.previewCwd)
        let app = launchHome(live)
        let row = app.buttons["sessions.agent.\(paneId)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The shell pane never appeared on the home.")
        openTerminal(app, row: row)
        // Some output in scrollback so each open has something to render.
        let surface = app.descendants(matching: .any)["terminal.surface"]
        surface.tap()
        surface.typeText("for i in $(seq 1 300); do echo \"scrollback line $i $RANDOM\"; done\n")
        app.buttons["terminal.dismissKeyboard"].tap()
        closeTerminal(app)

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTMemoryMetric(application: app), XCTClockMetric()], options: options) {
            for _ in 0..<cyclesPerIteration {
                openTerminal(app, row: row)
                closeTerminal(app)
            }
        }
        try await leaksWindow(live, label: "terminal-cycles")
    }

    @MainActor
    func testTerminalStaysOpen() async throws {
        let live = try liveEnvironment()
        let minutes = try soakMinutes()
        let paneId = try await createShell(live, cwd: live.previewCwd)
        let app = launchHome(live)
        let row = app.buttons["sessions.agent.\(paneId)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The shell pane never appeared on the home.")
        openTerminal(app, row: row)
        let surface = app.descendants(matching: .any)["terminal.surface"]
        // Keys typed before the terminal is connected are dropped, so give
        // the attach a moment, then prove the stream is flowing before the
        // hour starts.
        sleep(3)
        surface.tap()
        // Five lines a second for the whole stay — a chatty agent, not a quiet one.
        surface.typeText("while true; do echo \"streamed output line $RANDOM $(date +%T)\"; sleep 0.2; done\n")
        app.buttons["terminal.dismissKeyboard"].tap()
        let started = Date()
        while ((surface.value as? String) ?? "").contains("streamed output line") == false {
            XCTAssertLessThan(Date().timeIntervalSince(started), 20, "The output loop never started; the keystrokes did not reach the shell.")
            sleep(1)
        }

        let deadline = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        var previous = ""
        while Date() < deadline {
            try await Task.sleep(for: .seconds(60))
            // Liveness = the accessible transcript keeps changing, and it
            // reads as whole rows: since #71 it comes from Ghostty's grid, so
            // herdr's screen diffs (only the changed cells of rows that all
            // start with the same words) no longer leave fragments.
            var now = ""
            for _ in 0..<5 where now.isEmpty || now == previous {
                now = (app.descendants(matching: .any)["terminal.surface"].value as? String) ?? ""
                if now.isEmpty || now == previous { sleep(2) }
            }
            if now.isEmpty || now == previous, let dir = live.syncDir {
                try? now.write(to: URL(fileURLWithPath: dir).appendingPathComponent("transcript-dump.txt"), atomically: true, encoding: .utf8)
            }
            XCTAssertFalse(now.isEmpty, "The terminal's transcript went empty: the stream or the surface is gone.")
            XCTAssertNotEqual(now, previous, "The terminal screen has not changed in a minute: the stream stalled.")
            XCTAssertTrue(now.contains("streamed output line"), "The transcript no longer reads as whole rows (#71): \(now.prefix(200))")
            previous = now
        }
        try await leaksWindow(live, label: "terminal-stay")
        surface.tap()
        surface.typeText("\u{3}")
        app.buttons["terminal.dismissKeyboard"].tap()
        closeTerminal(app)
    }

    // MARK: - Steps

    @MainActor
    private func openPreview(_ app: XCUIApplication, expectConsent: Bool) {
        let preview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'terminal.preview'")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.tap()
        if expectConsent {
            XCTAssertTrue(app.descendants(matching: .any)["preview.consent"].waitForExistence(timeout: 20),
                          "No single dev server found; the chooser opened instead.")
            app.buttons["preview.consent.open"].tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["preview.web"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.descendants(matching: .any)["preview.banner"].exists, "The page opened but the sheet shows a problem banner.")
    }

    @MainActor
    private func closePreview(_ app: XCUIApplication) {
        app.buttons["preview.done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["preview.sheet"].waitForNonExistence(timeout: 10))
    }

    @MainActor
    private func openTerminal(_ app: XCUIApplication, row: XCUIElement) {
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal.surface"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func closeTerminal(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal.surface"].waitForNonExistence(timeout: 10))
    }

    // The outside sampler (`scripts/memsample.sh`) watches the sync directory:
    // when `leaks-<label>` appears it runs `leaks` on the app and removes the
    // file. Without a sync directory this is a no-op.
    private func leaksWindow(_ live: LiveEnvironment, label: String) async throws {
        guard let dir = live.syncDir else { return }
        let marker = URL(fileURLWithPath: dir).appendingPathComponent("leaks-\(label)")
        try Data().write(to: marker)
        let deadline = Date().addingTimeInterval(240)
        while FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            try await Task.sleep(for: .seconds(2))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Nobody ran leaks within four minutes; is memsample.sh running?")
    }

    // MARK: - Live host plumbing

    private struct LiveEnvironment {
        let host: String
        let token: String
        let previewCwd: String
        let syncDir: String?
    }

    private func liveEnvironment() throws -> LiveEnvironment {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TAVI_MEMORY"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_MEMORY=1 to run the memory checks (minutes each, live host).")
        }
        guard let host = environment["TAVI_DEV_HOST"], let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run against a live host.")
        }
        guard let cwd = environment["TAVI_AUDIT_PREVIEW_CWD"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_AUDIT_PREVIEW_CWD to a folder with a dev server running (the Vite demo).")
        }
        return LiveEnvironment(host: host, token: token, previewCwd: cwd, syncDir: environment["TAVI_MEMORY_SYNC_DIR"])
    }

    private func soakMinutes() throws -> Int {
        guard let raw = ProcessInfo.processInfo.environment["TAVI_MEMORY_SOAK_MINUTES"], let minutes = Int(raw), minutes > 0 else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_MEMORY_SOAK_MINUTES to run the long stay.")
        }
        return minutes
    }

    @MainActor
    private func launchIntoPreviewShell(_ live: LiveEnvironment) async throws -> XCUIApplication {
        let paneId = try await createShell(live, cwd: live.previewCwd)
        let app = XCUIApplication()
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launchEnvironment["TAVI_DEV_HOST"] = live.host
        app.launchEnvironment["TAVI_DEV_TOKEN"] = live.token
        app.launchEnvironment["TAVI_DEV_AGENT"] = paneId
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["terminal.surface"].waitForExistence(timeout: 20))
        sleep(2)
        return app
    }

    @MainActor
    private func launchHome(_ live: LiveEnvironment) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launchEnvironment["TAVI_DEV_HOST"] = live.host
        app.launchEnvironment["TAVI_DEV_TOKEN"] = live.token
        app.launch()
        return app
    }

    private func createShell(_ live: LiveEnvironment, cwd: String) async throws -> String {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(live.host)/api/herdr/tabs")))
        request.httpMethod = "POST"
        request.setValue("Bearer \(live.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["agent": "shell", "cwd": cwd, "allowOutsideRoots": true])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 201 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw XCTSkip("The host could not create a shell pane (HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))).")
        }
        let payload = try JSONDecoder().decode([String: String].self, from: data)
        let paneId = try XCTUnwrap(payload["paneId"])
        let tabId = try XCTUnwrap(payload["tabId"])
        addTeardownBlock {
            var close = URLRequest(url: URL(string: "\(live.host)/api/herdr/tabs/\(tabId)")!)
            close.httpMethod = "DELETE"
            close.setValue("Bearer \(live.token)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: close)
        }
        return paneId
    }
}
