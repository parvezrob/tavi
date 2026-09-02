import XCTest

// The design-audit harness (#54): walks every screen in its real states and
// keeps a screenshot of each. Not a test of behavior — it skips unless
// TAVI_AUDIT=1 so normal suite runs never pay for it. Run with the live
// host env; it stages its own disposable panes (a claude agent in a fresh
// tmp folder to force the trust dialog → a real needs-you state) and closes
// them in teardown.
final class TaviScreenshotAudit: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testCaptureAuditScreens() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TAVI_AUDIT"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_AUDIT=1 to capture the design-audit screens.")
        }
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the audit against a live host.")
        }

        // 1. First-run: the empty home and the pairing sheet.
        let app = XCUIApplication()
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["sessions.scanPairingCode"].waitForExistence(timeout: 10))
        keep("audit-01-empty-home")
        app.buttons["sessions.scanPairingCode"].tap()
        _ = app.textViews["pairing.manualCode"].firstMatch.waitForExistence(timeout: 8)
            || app.textFields["pairing.manualCode"].firstMatch.waitForExistence(timeout: 2)
        keep("audit-02-pairing")
        app.terminate()

        // 2. Stage a real needs-you: claude in a fresh tmp folder trusts
        // nothing and blocks on the trust dialog.
        let blocked = try await createAgentTab(host: host, token: token, cwd: "/private/tmp", agent: "claude")
        _ = await waitForStatus(host: host, token: token, paneId: blocked.paneId, status: "blocked", timeout: 90)

        // 3. The populated home, needs-you leading.
        app.launchEnvironment["TAVI_DEV_HOST"] = host
        app.launchEnvironment["TAVI_DEV_TOKEN"] = token
        app.launch()
        let anyCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.agent.'")).firstMatch
        XCTAssertTrue(anyCard.waitForExistence(timeout: 30), "The home never showed agents.")
        _ = app.buttons["sessions.agent.\(blocked.paneId)"].waitForExistence(timeout: 30)
        keep("audit-03-home")

        // 4. The permission decision sheet for the blocked agent.
        let blockedCard = app.buttons["sessions.agent.\(blocked.paneId)"]
        if blockedCard.waitForExistence(timeout: 10) {
            blockedCard.tap()
            _ = app.staticTexts["Needs you"].waitForExistence(timeout: 5)
            sleep(2)
            keep("audit-04-decision-sheet")
        }
        app.terminate()

        // 5. New agent sheet.
        app.launch()
        XCTAssertTrue(app.buttons["sessions.newAgentTab"].waitForExistence(timeout: 20))
        app.buttons["sessions.newAgentTab"].tap()
        sleep(2)
        keep("audit-05-new-agent")
        app.terminate()

        // 6. Settings and This iPhone.
        app.launch()
        XCTAssertTrue(app.buttons["sessions.hostMenu"].waitForExistence(timeout: 20))
        app.buttons["sessions.hostMenu"].tap()
        XCTAssertTrue(app.buttons["sessions.settings"].waitForExistence(timeout: 5))
        app.buttons["sessions.settings"].tap()
        XCTAssertTrue(app.sliders["settings.fontSize"].waitForExistence(timeout: 10))
        sleep(2)
        keep("audit-06-settings")
        if app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.host.'")).firstMatch.exists {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.host.'")).firstMatch.tap()
            sleep(2)
            keep("audit-07-this-iphone")
        }
        app.terminate()

        // 7. The terminal: quiet, live typing, and the jump sheet.
        let shell = try await createAgentTab(host: host, token: token, cwd: "/private/tmp", agent: "shell")
        app.launchEnvironment["TAVI_DEV_AGENT"] = shell.paneId
        app.launch()
        // The banner only shows off-nominal now; the surface is the wait.
        _ = app.descendants(matching: .any)["terminal.surface"].waitForExistence(timeout: 20)
        sleep(3)
        keep("audit-08-terminal")
        let surface = app.otherElements["terminal.surface"]
        if surface.exists {
            surface.tap()
            _ = app.keyboards.element.waitForExistence(timeout: 5)
            keep("audit-09-terminal-typing")
        }
        if app.buttons["terminal.jump"].exists {
            app.buttons["terminal.jump"].tap()
            sleep(2)
            keep("audit-10-jump-sheet")
        }
    }

    // The several-computer home (#50) without a second machine on hand:
    // the same live host seeded twice under two names is enough to look at
    // the chip strip, the computer on every row, and the project cards
    // below the fold. Skips like the audit above.
    @MainActor
    func testCaptureHomeTwoComputers() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TAVI_AUDIT"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_AUDIT=1 to capture the design-audit screens.")
        }
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the audit against a live host.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launchEnvironment["TAVI_DEV_HOST"] = "\(host),\(host):443"
        app.launchEnvironment["TAVI_DEV_HOST_NAMES"] = "MacBook Air,robin-PC"
        app.launchEnvironment["TAVI_DEV_TOKEN"] = token
        app.launch()
        let anyCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.agent.'")).firstMatch
        XCTAssertTrue(anyCard.waitForExistence(timeout: 30), "The home never showed agents.")
        sleep(2)
        keep("audit-03b-home-two-computers-top")
        // A waiting row opens the decision sheet, which names the computer.
        let waiting = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.agent.'")).firstMatch
        if app.staticTexts["sessions.needsYou"].exists || app.otherElements["sessions.needsYou"].exists {
            waiting.tap()
            XCTAssertTrue(app.staticTexts["Needs you"].waitForExistence(timeout: 5), "The waiting row did not open the decision sheet.")
            sleep(1)
            keep("audit-03b2-decision-sheet-from-row")
            app.swipeDown(velocity: .fast)
            sleep(1)
        }
        app.swipeUp()
        sleep(1)
        keep("audit-03c-home-two-computers-scrolled")
        app.swipeUp()
        sleep(1)
        keep("audit-03d-home-two-computers-end")
        // Filter to one computer: the chip's own name drops off its rows.
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.computer.address'")).element(boundBy: 1)
        if chip.exists {
            app.swipeDown(); app.swipeDown()
            chip.tap()
            sleep(1)
            keep("audit-03e-home-filtered")
        }
    }

    // Changed files and one diff (#25) against a repository with real
    // uncommitted work: TEST_RUNNER_TAVI_AUDIT_CWD names it (default: the
    // Tavi checkout). Skips like the audit above.
    @MainActor
    func testCaptureChangedFilesAndDiff() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TAVI_AUDIT"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_AUDIT=1 to capture the design-audit screens.")
        }
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the audit against a live host.")
        }
        let cwd = environment["TAVI_AUDIT_CWD"] ?? "\(NSHomeDirectory())/Projects/tavi"
        let shell = try await createAgentTab(host: host, token: token, cwd: cwd, agent: "shell")
        let app = XCUIApplication()
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launchEnvironment["TAVI_DEV_HOST"] = host
        app.launchEnvironment["TAVI_DEV_TOKEN"] = token
        app.launchEnvironment["TAVI_DEV_AGENT"] = shell.paneId
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["terminal.surface"].waitForExistence(timeout: 20))
        sleep(2)
        app.buttons["terminal.files"].tap()
        app.buttons["Changed"].tap()
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'files.changed.'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20), "No changed files in \(cwd).")
        sleep(1)
        keep("audit-11-files-changed")
        first.tap()
        XCTAssertTrue(app.descendants(matching: .any)["files.viewer.diff"].waitForExistence(timeout: 15))
        sleep(1)
        keep("audit-12-files-diff")
    }

    // Dev-server preview (#58) against a real dev server running in
    // TEST_RUNNER_TAVI_AUDIT_PREVIEW_CWD (default: ~/Projects/preview-demo, a
    // Vite app on localhost:5173). The host must find exactly one server
    // there, so the sheet goes straight to consent. Skips like the audit.
    // Source Control — Changes (#77): opens the sheet from a worktree's
    // header on the home, stages the first file, lets Claude write the
    // message, commits, and keeps a screenshot of each step. Needs a
    // worktree with uncommitted changes and an agent in it, named by
    // TEST_RUNNER_TAVI_AUDIT_WORKTREE; the commit is real, in that branch.
    @MainActor
    func testCaptureSourceControl() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TAVI_AUDIT"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_AUDIT=1 to capture the design-audit screens.")
        }
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"],
              let worktree = environment["TAVI_AUDIT_WORKTREE"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN and TEST_RUNNER_TAVI_AUDIT_WORKTREE.")
        }

        let app = XCUIApplication()
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launchEnvironment["TAVI_DEV_HOST"] = host
        app.launchEnvironment["TAVI_DEV_TOKEN"] = token
        app.launch()

        let header = app.buttons["sessions.worktree.\(worktree)"]
        var tries = 0
        while !header.exists, tries < 8 {
            if tries == 0 { _ = header.waitForExistence(timeout: 20) } else { app.swipeUp() }
            tries += 1
        }
        XCTAssertTrue(header.exists, "The home never showed the worktree \(worktree).")
        keep("sc-00-home-worktree")
        header.tap()

        XCTAssertTrue(app.descendants(matching: .any)["sourceControl.sheet"].waitForExistence(timeout: 20), "Source Control did not open.")
        let firstFile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sourceControl.stage.'")).firstMatch
        XCTAssertTrue(firstFile.waitForExistence(timeout: 20), "No changed file was listed.")
        keep("sc-01-changes")

        firstFile.tap()
        sleep(3)
        keep("sc-02-staged")

        let write = app.buttons["sourceControl.writeMessage"]
        XCTAssertTrue(write.waitForExistence(timeout: 5))
        write.tap()
        let commit = app.buttons["sourceControl.commit"]
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, !commit.isEnabled { sleep(1) }
        XCTAssertTrue(commit.isEnabled, "Commit never became enabled — did Claude write a message?")
        keep("sc-03-message")

        commit.tap()
        XCTAssertTrue(app.staticTexts["sourceControl.notice"].waitForExistence(timeout: 30), "No commit receipt.")
        sleep(2)
        keep("sc-04-committed")

        app.buttons["Pull request"].firstMatch.tap()
        keep("sc-05-pull-request")
        app.buttons["Commits"].firstMatch.tap()
        keep("sc-06-commits")
    }

    @MainActor
    func testCapturePreviewDevServer() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TAVI_AUDIT"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_AUDIT=1 to capture the design-audit screens.")
        }
        guard let host = environment["TAVI_DEV_HOST"],
              let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run the audit against a live host.")
        }
        let cwd = environment["TAVI_AUDIT_PREVIEW_CWD"] ?? "\(NSHomeDirectory())/Projects/preview-demo"
        let shell = try await createAgentTab(host: host, token: token, cwd: cwd, agent: "shell")
        let app = XCUIApplication()
        app.launchEnvironment["TAVI_DEV_RESET"] = "1"
        app.launchEnvironment["TAVI_DEV_HOST"] = host
        app.launchEnvironment["TAVI_DEV_TOKEN"] = token
        app.launchEnvironment["TAVI_DEV_AGENT"] = shell.paneId
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["terminal.surface"].waitForExistence(timeout: 20))
        sleep(2)
        let preview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'terminal.preview'")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.tap()
        let consent = app.descendants(matching: .any)["preview.consent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 20), "No single dev server found in \(cwd); the chooser opened instead.")
        sleep(1)
        keep("audit-13-preview-consent")
        app.buttons["preview.consent.open"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["preview.web"].waitForExistence(timeout: 20))
        sleep(4)
        keep("audit-14-preview-page")
        XCTAssertFalse(app.descendants(matching: .any)["preview.banner"].exists, "The page opened but the sheet shows a problem banner.")

        // Hot reload through the door: edit the page's source on the computer
        // and the change must reach the phone without a tap (Vite pushes it
        // over its WebSocket, which the door pipes raw).
        let mainFile = URL(fileURLWithPath: "\(cwd)/src/main.js")
        if let original = try? String(contentsOf: mainFile, encoding: .utf8), original.contains("Get started") {
            let marker = "Reloaded \(Int(Date().timeIntervalSince1970) % 100_000)"
            addTeardownBlock { try? original.write(to: mainFile, atomically: true, encoding: .utf8) }
            try original.replacingOccurrences(of: "Get started", with: marker).write(to: mainFile, atomically: true, encoding: .utf8)
            let reloaded = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
            XCTAssertTrue(reloaded.waitForExistence(timeout: 15), "The edit did not reach the phone: hot reload is not flowing through the door.")
            sleep(1)
            keep("audit-14b-preview-hot-reloaded")
        }
        app.buttons["preview.menu"].tap()
        sleep(1)
        keep("audit-15-preview-menu")
        app.buttons["Another port"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["preview.chooser"].waitForExistence(timeout: 10))
        sleep(1)
        keep("audit-16-preview-chooser")
        app.buttons["preview.done"].tap()
    }

    // MARK: - Helpers (self-contained; the main suite's are private)

    @MainActor
    private func keep(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func createAgentTab(
        host: String,
        token: String,
        cwd: String,
        agent: String
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
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw XCTSkip("The host could not create a disposable agent tab for the audit (HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))).")
        }
        let payload = try JSONDecoder().decode([String: String].self, from: data)
        let paneId = try XCTUnwrap(payload["paneId"])
        let tabId = try XCTUnwrap(payload["tabId"])
        addTeardownBlock {
            var close = URLRequest(url: URL(string: "\(host)/api/herdr/tabs/\(tabId)")!)
            close.httpMethod = "DELETE"
            close.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: close)
        }
        return (paneId, tabId)
    }

    private func waitForStatus(
        host: String,
        token: String,
        paneId: String,
        status: String,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var request = URLRequest(url: URL(string: "\(host)/api/agents")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let (data, _) = try? await URLSession.shared.data(for: request),
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let agents = payload["agents"] as? [[String: Any]],
               agents.contains(where: { $0["id"] as? String == paneId && $0["status"] as? String == status }) {
                return true
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }
}
