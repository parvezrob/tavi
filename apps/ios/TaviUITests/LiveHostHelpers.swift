import XCTest

// The address and token every live suite was started with (#111).
struct LiveEnvironment {
    let host: String
    let token: String

    static func current() throws -> LiveEnvironment {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TAVI_DEV_HOST"], let token = environment["TAVI_DEV_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_DEV_HOST/TOKEN to run against a live host.")
        }
        return LiveEnvironment(host: host, token: token)
    }
}

struct ProjectCatalogBody: Decodable {
    struct Folder: Decodable { let path: String; let active: Bool; let withinRoots: Bool }
    struct Workspace: Decodable { let path: String }
    let recent: [Folder]
    let workspaces: [Workspace]
}

extension XCTestCase {
    // The host requires an explicit project folder (#24). These live tests
    // only need an agent running somewhere real, so they confirm the custom
    // location outright; the roots gate itself is covered by host tests.
    func createAgentTab(
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
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw XCTSkip("The host could not create a disposable agent tab (HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))).")
        }
        let payload = try JSONDecoder().decode([String: String].self, from: data)
        return (try XCTUnwrap(payload["paneId"]), try XCTUnwrap(payload["tabId"]))
    }

    static func closeAgentTab(host: String, token: String, tabId: String) async throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(host)/api/herdr/tabs/\(tabId)")))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await URLSession.shared.data(for: request)
    }

    // The terminal tests run in a shell pane of their own (#42) inside a real
    // project folder, closed again in teardown — the owner's live agents are
    // never touched.
    func createDisposableShell(host: String, token: String) async throws -> String {
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
    func launchIntoAgent(
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

    // A connected terminal is silent (#54): no status bar, input chrome
    // present. A failed one collapses the chrome and shows its verdict.
    @MainActor
    func waitForLiveTerminal(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
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
    func waitForTranscript(
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

    // A real folder on this Mac to start a disposable agent in, read from the
    // host's own project catalog rather than hard-coding one machine's layout.
    // It prefers a folder inside the configured roots, so creating there needs
    // no confirmation, and among those one an agent is already running in —
    // the best available hint that Claude trusts it. Nothing here proves
    // trust, so callers needing an idle agent must treat a trust prompt as a
    // skip rather than a failure.
    func knownProjectPath(host: String, token: String) async throws -> String {
        let catalog = try await projectCatalog(host: host, token: token)
        let insideRoots = catalog.recent.filter(\.withinRoots)
        guard let path = insideRoots.first(where: \.active)?.path
            ?? insideRoots.first?.path
            ?? catalog.workspaces.first?.path else {
            throw XCTSkip("This host has no project folder inside its roots to start a disposable agent in.")
        }
        return path
    }

    func projectCatalog(host: String, token: String) async throws -> ProjectCatalogBody {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(host)/api/projects")))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("The host could not list its projects.")
        }
        return try JSONDecoder().decode(ProjectCatalogBody.self, from: data)
    }
}
