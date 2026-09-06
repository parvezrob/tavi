import XCTest

// What the soak needs beside its two phases (#111): how it reads the phone,
// the history the phone cannot keep, and the second client that makes a
// takeover a takeover.

// How the run talks to the chaos host: one place that knows the routes, the
// timeouts, and that a refusal is a failure of the run rather than a
// tolerated outcome.
@MainActor
extension TaviChaosSoak {
    @discardableResult
    func request(
        _ chaos: ChaosEnvironment,
        _ name: String,
        _ fault: FaultRequest,
        scoredForRecovery: Bool = true
    ) async throws -> Double {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(chaos.host)/api/chaos/fault")))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(chaos.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(fault)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        // A 404 means the fault had nothing to hit, which is a failure of the
        // run rather than a tolerated outcome.
        guard status == 201, let ack = try? JSONDecoder().decode(FaultAck.self, from: data) else {
            XCTFail("The chaos host refused \(name): HTTP \(status) \(String(bytes: data.prefix(200), encoding: .utf8) ?? "")")
            throw ChaosSoakFailure.faultRefused
        }
        fired.append(
            FiredFault(
                name: name,
                id: ack.id,
                at: ack.at,
                socket: fault.socket,
                thenSlowReadyMs: fault.thenSlowReadyMs,
                scoredForRecovery: scoredForRecovery
            )
        )
        return ack.at
    }

    func chaosFaults(_ chaos: ChaosEnvironment) async throws -> [ChaosFaultRecord] {
        try await get(chaos, "/api/chaos/events", as: ChaosFaultList.self).events
    }

    func chaosAttachments(_ chaos: ChaosEnvironment) async throws -> [ChaosAttachment] {
        try await get(chaos, "/api/chaos/attachments", as: ChaosAttachmentList.self).attachments
    }

    func get<T: Decodable>(_ chaos: ChaosEnvironment, _ path: String, as type: T.Type) async throws -> T {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(chaos.host)\(path)")))
        request.timeoutInterval = 10
        request.setValue("Bearer \(chaos.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            XCTFail("The chaos host did not answer \(path); was it started with TAVI_CHAOS=on?")
            throw ChaosSoakFailure.routeUnavailable
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // The runner's own record of the host being up. It is evidence about the
    // runner's path to the host, and is reported as exactly that.
    func poll(_ chaos: ChaosEnvironment) async -> HealthPoll {
        guard let url = URL(string: "\(chaos.host)/api/health") else { return HealthPoll(at: milliseconds(), answered: false) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        let answered = (try? await URLSession.shared.data(for: request)).map { ($0.1 as? HTTPURLResponse)?.statusCode != nil } ?? false
        return HealthPoll(at: milliseconds(), answered: answered)
    }
}

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
    // Sorted by the phone's monotonic stamp, ties broken by the order the ring
    // handed them over — so two events the phone stamped in the same
    // millisecond still stand in the order they happened.
    private var entries: [(seq: Int, event: DiagnosticsEvent)] = []
    private var seen: Set<String> = []

    var events: [DiagnosticsEvent] { entries.map(\.event) }

    func merge(_ line: DiagnosticsLine) {
        for event in line.ring where seen.insert(Self.key(event)).inserted {
            entries.append((entries.count, event))
        }
        entries.sort { ($0.event.monotonic, $0.seq) < ($1.event.monotonic, $1.seq) }
    }

    // Anchored on a host timestamp — a fault's `at`. Both sides export whole
    // milliseconds, so a cycle inside the fault's own millisecond belongs to
    // the window rather than before it.
    func first(_ source: String, _ kind: String, at anchor: Double) -> DiagnosticsEvent? {
        events.first { $0.source == source && $0.kind == kind && Double($0.at) >= anchor }
    }

    // Anchored on another of the phone's own events: strictly the events that
    // stand after it in the merged order, never the anchor itself and never a
    // same-millisecond predecessor.
    func first(_ source: String, _ kind: String, after event: DiagnosticsEvent) -> DiagnosticsEvent? {
        guard let index = entries.firstIndex(where: { Self.key($0.event) == Self.key(event) }) else { return nil }
        return entries[(index + 1)...].first { $0.event.source == source && $0.event.kind == kind }?.event
    }

    private static func key(_ event: DiagnosticsEvent) -> String {
        "\(event.source)|\(event.monotonic)|\(event.kind)|\(event.reason)"
    }

    func all(_ source: String, _ kind: String, from: Double, to: Double) -> [DiagnosticsEvent] {
        events.filter { $0.source == source && $0.kind == kind && Double($0.at) >= from && Double($0.at) <= to }
    }
}

// A second real `tavi.v2` client, which is what makes a takeover a takeover.
// It only has to connect without resume parameters and keep draining.
final class TakeoverClient: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var ready: Double?
    private var problem: String?

    // When the host said `ready` to this client — the moment the phone's
    // attachment was actually taken, which is what the superseded sentence
    // is measured from.
    var readyAt: Double? { lock.withLock { ready } }
    // Anything that ended the drain: the host closing or failing this
    // connection while it was supposed to be holding the pane.
    var failure: String? { lock.withLock { problem } }

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
            guard let self else { return }
            switch result {
            case let .success(message):
                note(message)
                drain()
            case let .failure(error):
                lock.withLock { if problem == nil { problem = "\(error)" } }
            }
        }
    }

    // The v2 `ready` is a JSON text frame; nothing else here needs decoding.
    private func note(_ message: URLSessionWebSocketTask.Message) {
        guard case let .string(text) = message, text.contains("\"type\":\"ready\"") else { return }
        lock.withLock { if ready == nil { ready = Date().timeIntervalSince1970 * 1_000 } }
    }
}

extension URL {
    var wsScheme: URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        return components.url
    }
}
