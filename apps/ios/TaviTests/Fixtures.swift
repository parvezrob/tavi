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
        // Nothing came back: asleep, off the tailnet, or this phone is offline.
        case silence
    }

    private var answers: [Answer]
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

    nonisolated var transport: HostClient.Transport {
        { request in try await self.answer(request) }
    }

    private func answer(_ request: URLRequest) throws -> (Data, URLResponse) {
        lastRequest = request
        guard let url = request.url else { throw URLError(.badURL) }
        calls.append("\(request.httpMethod ?? "GET") \(url.path)")
        // A script that has run out keeps answering silence, so a test that
        // retries never falls through to a stale reply.
        let answer = answers.isEmpty ? Answer.silence : answers.removeFirst()
        guard case let .json(status, body) = answer else { throw URLError(.cannotConnectToHost) }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            throw URLError(.badServerResponse)
        }
        return (Data(body.utf8), response)
    }
}
