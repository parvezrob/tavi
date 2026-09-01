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
        if app.buttons["settings.thisIPhone"].exists {
            app.buttons["settings.thisIPhone"].tap()
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
            throw XCTSkip("The host could not create a disposable agent tab for the audit.")
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
