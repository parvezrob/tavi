import Foundation
@testable import Tavi
import Testing

// Defaults are the values the suites already built by hand, so no assertion changes meaning.
enum Fixtures {
    static func agentSummary(
        id: String = "pane-1",
        agent: String = "claude",
        status: String = "working",
        cwd: String = "/Users/dev/projects/tavi",
        title: String = "",
        workspaceId: String = "ws-1",
        tabId: String = "tab-1",
        tabLabel: String? = nil,
        focused: Bool = false
    ) -> AgentSummary {
        AgentSummary(
            id: id,
            agent: agent,
            status: status,
            cwd: cwd,
            title: title,
            workspaceId: workspaceId,
            tabId: tabId,
            tabLabel: tabLabel,
            focused: focused
        )
    }

    static func hostEndpoint(_ baseURL: String = "https://studio.tailnet.ts.net") throws -> HostEndpoint {
        try HostEndpoint(baseURL: #require(URL(string: baseURL)))
    }

    static func hostClient(_ host: StubHost, credential: String = "secret") throws -> HostClient {
        HostClient(endpoint: try hostEndpoint(), credential: credential, transport: host.transport)
    }

    static func pairedHost(
        id: String = "fp-1",
        hostName: String = "studio-mac",
        address: String = "https://studio.tailnet.ts.net",
        alias: String? = nil
    ) -> PairedHost {
        PairedHost(
            id: id,
            hostName: hostName,
            address: address,
            fingerprint: id,
            deviceId: "device-1",
            deviceName: "iPhone",
            pairedAt: Date(timeIntervalSince1970: 0),
            alias: alias
        )
    }

    // The `agents` frame the events stream pushes, as the host writes it.
    static func agentsFrame(status: String = "working", available: Bool = true) -> String {
        """
        {"type":"agents","available":\(available),"agents":[{"id":"pane-1","agent":"claude",
         "status":"\(status)","cwd":"/repo","title":"","workspaceId":"ws-1","tabId":"tab-1","focused":true}]}
        """
    }

    @MainActor
    static func hostRoutes(_ host: StubHost, hostId: String = "host-1") throws -> HostRoutes {
        let routes = HostRoutes(transport: host.transport)
        routes.configure(host: try hostEndpoint(), credential: "secret", hostId: hostId)
        return routes
    }
}

// A paired computer that answers from a script instead of the network
// (#99), so no unit test opens a socket.
actor StubHost {
    enum Answer: Sendable {
        // A status with the JSON body the host sent beside it.
        case json(Int, String)
        // A body the host labelled itself, for a route that reads the type.
        case body(Int, String, mime: String)
        // Nothing came back: asleep, off the tailnet, or this phone is offline.
        case silence
    }

    private var answers: [Answer]
    // Answers keyed by "GET /api/repos", for an object that makes several
    // kinds of call at once; an unrouted path gets silence.
    private var routes: [String: Answer] = [:]
    // "GET /api/repos" per call: eleven rewritten request builders invite
    // exactly one regression, a route asking the wrong address (#99).
    private(set) var calls: [String] = []
    private(set) var lastRequest: URLRequest?

    init(_ answers: Answer...) {
        self.answers = answers
    }

    init(_ answers: [Answer]) {
        self.answers = answers
    }

    init(routing routes: [String: Answer]) {
        answers = []
        self.routes = routes
    }

    nonisolated var transport: HostClient.Transport {
        { request in try await self.answer(request) }
    }

    private func answer(_ request: URLRequest) throws -> (Data, URLResponse) {
        lastRequest = request
        guard let url = request.url else { throw URLError(.badURL) }
        calls.append("\(request.httpMethod ?? "GET") \(url.path)")
        // A script that has run out keeps answering silence, so a test that
        // retries never falls through to a stale reply.
        let answer = routes.isEmpty
            ? (answers.isEmpty ? Answer.silence : answers.removeFirst())
            : routes[calls[calls.count - 1]] ?? .silence
        let status: Int
        let body: String
        let mime: String
        switch answer {
        case let .json(code, text): (status, body, mime) = (code, text, "application/json")
        case let .body(code, text, type): (status, body, mime) = (code, text, type)
        case .silence: throw URLError(.cannotConnectToHost)
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": mime]
        ) else {
            throw URLError(.badServerResponse)
        }
        return (Data(body.utf8), response)
    }
}

// A scripted events socket. The lock is the whole invariant: the script is
// read from the link's task and written by nobody else.
final class FakeEventsSocket: HostEventsSocketing, @unchecked Sendable {
    enum Line: Sendable {
        case frame(String)
        case drop
        // A host with nothing to say, until the link is stopped.
        case quiet
    }

    private let lock = NSLock()
    private var script: [Line]

    init(_ script: Line...) {
        self.script = script
    }

    var lastActivity: ContinuousClock.Instant { ContinuousClock().now }

    func resume() {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        let next = lock.withLock { script.isEmpty ? Line.quiet : script.removeFirst() }
        switch next {
        case let .frame(text):
            return .string(text)
        case .drop:
            throw URLError(.networkConnectionLost)
        case .quiet:
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
    }

    func ping() async throws {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
}

// One socket per dial, in order; a dial past the script gets a quiet host.
final class FakeSockets: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [FakeEventsSocket]

    init(_ queued: [FakeEventsSocket] = []) {
        self.queued = queued
    }

    @Sendable
    func make(_ request: URLRequest) -> any HostEventsSocketing {
        lock.withLock { queued.isEmpty ? FakeEventsSocket(.quiet) : queued.removeFirst() }
    }
}

// Waits for a condition the object reaches on its own tasks; no sleeps
// with a guessed duration, and a miss is recorded rather than hung on.
@MainActor
func waitUntil(_ seconds: Int = 3, _ condition: () -> Bool) async throws {
    for _ in 0..<(seconds * 50) {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("the condition never became true")
}
