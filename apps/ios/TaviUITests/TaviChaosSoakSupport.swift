import XCTest

// What the soak needs beside its two phases (#111): how it reads the phone,
// the history the phone cannot keep, and the second client that makes a
// takeover a takeover.

// Everything the run learns comes through the two elements the app publishes
// under a scripted launch; both are bound by their exact identifier, pinned
// once at smoke time.
@MainActor
extension TaviChaosSoak {
    func smokeDiagnostics(_ app: XCUIApplication) throws -> DiagnosticsLine {
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'diagnostics.recovery.'")).firstMatch
        guard element.waitForExistence(timeout: 30), let value = element.value as? String, !value.isEmpty else {
            throw XCTSkip("No diagnostics element: the app was not launched with TAVI_DEV_HOST, or this is not a DEBUG build.")
        }
        let line = try JSONDecoder().decode(DiagnosticsLine.self, from: Data(value.utf8))
        XCTAssertFalse(line.host.isEmpty, "The diagnostics element carries no host id.")
        diagnosticsIdentifier = "diagnostics.recovery.\(line.host)"
        healthIdentifiers = Self.healthStates.map { ("sessions.health.\(line.host).\($0)", $0) }
        // The home publishes exactly one of these per computer. Missing here
        // means the soak would have measured nothing at minute eighteen.
        XCTAssertNotNil(currentHealth(app), "The home publishes no sessions.health.\(line.host).* element.")
        return line
    }

    // The state the home is showing for the soak's computer, bound by exact
    // identifier: the state is part of the identifier, so each is asked for.
    func currentHealth(_ app: XCUIApplication) -> String? {
        healthIdentifiers.first { app.descendants(matching: .any)[$0.identifier].exists }?.state
    }

    func readDiagnostics(_ app: XCUIApplication) async throws -> DiagnosticsLine {
        let element = app.descendants(matching: .any)[diagnosticsIdentifier]
        guard element.waitForExistence(timeout: 30), let value = element.value as? String, !value.isEmpty else {
            XCTFail("The diagnostics element \(diagnosticsIdentifier) went away mid-run.")
            throw ChaosSoakFailure.diagnosticsUnreadable
        }
        return try JSONDecoder().decode(DiagnosticsLine.self, from: Data(value.utf8))
    }

    // How long this source has been up, from its own events: the newest
    // `ready` with nothing that ended a stream after it.
    func liveSeconds(_ source: String) -> Double? {
        guard let ready = lastReadyAt(source) else { return nil }
        let ended = collector.events.last { $0.source == source && ($0.kind == "cycling" || $0.kind == "streamEnded") }
        if let ended, Double(ended.at) > ready { return nil }
        return (milliseconds() - ready) / 1_000
    }

    func lastReadyAt(_ source: String) -> Double? {
        collector.events.last { $0.source == source && $0.kind == "ready" }.map { Double($0.at) }
    }
}

// The complete history the phone cannot keep: every ring event this run ever
// saw, merged by the monotonic timestamp the phone stamped it with.
final class RingCollector {
    private(set) var events: [DiagnosticsEvent] = []
    private var seen: Set<String> = []

    func merge(_ line: DiagnosticsLine) {
        for event in line.ring where seen.insert("\(event.source)|\(event.monotonic)|\(event.kind)|\(event.reason)").inserted {
            events.append(event)
        }
        events.sort { $0.monotonic < $1.monotonic }
    }

    func first(_ source: String, _ kind: String, after at: Double) -> DiagnosticsEvent? {
        events.first { $0.source == source && $0.kind == kind && Double($0.at) > at }
    }

    func all(_ source: String, _ kind: String, from: Double, to: Double) -> [DiagnosticsEvent] {
        events.filter { $0.source == source && $0.kind == kind && Double($0.at) > from && Double($0.at) <= to }
    }
}

// A second real `tavi.v2` client, which is what makes a takeover a takeover.
// It only has to connect without resume parameters and keep draining.
final class TakeoverClient: Sendable {
    private let task: URLSessionWebSocketTask

    init?(host: String, token: String, paneId: String) {
        guard let url = URL(string: "\(host)/api/agents/\(paneId)/terminal")?.wsScheme else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("tavi.v2", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        task = URLSession.shared.webSocketTask(with: request)
    }

    func start() {
        task.resume()
        drain()
    }

    func stop() { task.cancel(with: .goingAway, reason: nil) }

    private func drain() {
        task.receive { [weak self] result in
            guard case .success = result else { return }
            self?.drain()
        }
    }
}

extension URL {
    var wsScheme: URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        return components.url
    }
}
