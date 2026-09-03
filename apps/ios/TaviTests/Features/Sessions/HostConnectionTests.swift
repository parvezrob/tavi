import Foundation
@testable import Tavi
import Testing

// The link to one paired computer (#50, #86), driven through a scripted
// socket and a scripted host: every transition the home's header is made
// of — live, stale, revoked, offline — and the repos poll beside it.
@MainActor
struct HostConnectionTests {
    private static let snapshot = #"""
    {"type":"agents","available":true,"agents":[{"id":"pane-1","agent":"claude","status":"working",
     "cwd":"/repo","title":"","workspaceId":"ws-1","tabId":"tab-1","focused":true}]}
    """#

    @MainActor
    private final class Events {
        var snapshots: [[AgentSummary]] = []
        var revocations: [String] = []
    }

    private func link(
        sockets: [FakeEventsSocket],
        host: StubHost = StubHost()
    ) throws -> (HostConnection, Events) {
        let factory = FakeSockets(sockets)
        let connection = HostConnection(transport: host.transport, makeSocket: factory.make)
        let events = Events()
        connection.configure(host: try Fixtures.hostEndpoint(), credential: "secret") { event in
            switch event {
            case let .snapshot(agents, _, _): events.snapshots.append(agents)
            case let .revoked(reason): events.revocations.append(reason)
            }
        }
        return (connection, events)
    }

    private func waitUntil(_ seconds: Int = 3, _ condition: () -> Bool) async throws {
        for _ in 0..<(seconds * 50) {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the condition never became true")
    }

    // MARK: - Live

    @Test func theFirstSnapshotMakesTheLinkLive() async throws {
        let (connection, _) = try link(sockets: [FakeEventsSocket(.frame(Self.snapshot), .quiet)])
        defer { connection.stop() }
        try await waitUntil { connection.health == .live }
    }

    @Test func theFirstSnapshotIsHandedToTheDirectory() async throws {
        let (connection, events) = try link(sockets: [FakeEventsSocket(.frame(Self.snapshot), .quiet)])
        defer { connection.stop() }
        try await waitUntil { !events.snapshots.isEmpty }
        #expect(events.snapshots.first?.map(\.id) == ["pane-1"])
    }

    // MARK: - The stream drops

    // PRD §7.8: resume with an explicit stale indicator, never a blank
    // screen — a blocked agent stays visible through reconnects.
    @Test func aDroppedStreamKeepsWhatIsOnScreenAsStale() async throws {
        let (connection, _) = try link(
            sockets: [FakeEventsSocket(.frame(Self.snapshot), .drop)],
            host: StubHost(.json(200, "{}"), .json(200, "{}"))
        )
        defer { connection.stop() }
        try await waitUntil { connection.health == .stale }
    }

    @Test func theReposPollStopsWhileTheStreamIsDown() async throws {
        let (connection, _) = try link(
            sockets: [FakeEventsSocket(.frame(Self.snapshot), .drop)],
            host: StubHost(.json(200, "{}"), .json(200, "{}"))
        )
        defer { connection.stop() }
        try await waitUntil { connection.isPollable == false }
    }

    @Test func theReposPollRunsBesideALiveStream() async throws {
        let (connection, _) = try link(sockets: [FakeEventsSocket(.frame(Self.snapshot), .quiet)])
        defer { connection.stop() }
        try await waitUntil { connection.health == .live }
        #expect(connection.isPollable)
    }

    // The header says how the packets travel, learned from the same probe.
    @Test func theLinkLearnsHowThisPhoneReachesTheComputer() async throws {
        let (connection, _) = try link(
            sockets: [FakeEventsSocket(.frame(Self.snapshot), .drop)],
            host: StubHost(.json(200, #"{"connection":{"path":"relay","relay":"blr"}}"#))
        )
        defer { connection.stop() }
        try await waitUntil { connection.path == .relay("blr") }
    }

    // MARK: - Revoked

    // A WebSocket drop and an HTTP 401 look alike here, so the link asks
    // the host directly before deciding (#46).
    @Test func aDropWhoseProbeIsRejectedRevokesThePhone() async throws {
        let (connection, events) = try link(
            sockets: [FakeEventsSocket(.frame(Self.snapshot), .drop)],
            host: StubHost(.json(401, #"{"error":"Unauthorized."}"#))
        )
        defer { connection.stop() }
        try await waitUntil { !events.revocations.isEmpty }
    }

    // Retrying cannot fix a dead credential, so the stream stops.
    @Test func aRevokedLinkStopsDialling() async throws {
        let (connection, _) = try link(
            sockets: [FakeEventsSocket(.frame(Self.snapshot), .drop)],
            host: StubHost(.json(401, #"{"error":"Unauthorized."}"#))
        )
        defer { connection.stop() }
        try await waitUntil { connection.isRunning == false }
    }

    // MARK: - Offline

    // Earned, not guessed (#86): the first dial that fails is still
    // "Reconnecting"; Offline waits for the second, and for two probes.
    @Test func twoDialsThatProducedNoFrameSayOffline() async throws {
        let (connection, _) = try link(
            sockets: [FakeEventsSocket(.drop), FakeEventsSocket(.drop)],
            host: StubHost(.silence)
        )
        defer { connection.stop() }
        try await waitUntil(12) { connection.health == .offline }
    }

    @Test func aSnapshotAfterOfflineMakesTheLinkLiveAgain() async throws {
        let (connection, _) = try link(
            sockets: [
                FakeEventsSocket(.drop),
                FakeEventsSocket(.drop),
                FakeEventsSocket(.frame(Self.snapshot), .quiet),
            ],
            host: StubHost(.silence)
        )
        defer { connection.stop() }
        try await waitUntil(20) { connection.health == .live }
    }

    // MARK: - Leaving

    @Test func closingTheLinkLabelsWhatIsOnScreenStale() async throws {
        let (connection, _) = try link(sockets: [FakeEventsSocket(.frame(Self.snapshot), .quiet)])
        try await waitUntil { connection.health == .live }
        connection.stop()
        #expect(connection.health == .stale)
    }

    // Nothing can connect without a credential, and "Connecting…" forever
    // would be a fabricated state: say so with a revocation's offers (#46).
    @Test func aLinkWithNoCredentialIsRevokedRatherThanConnecting() {
        let connection = HostConnection(transport: StubHost().transport, makeSocket: FakeSockets([]).make)
        connection.configure(host: nil, credential: "") { _ in }
        #expect(connection.health == .revoked)
    }
}

// A scripted events socket. The lock is the whole invariant: the script is
// read from the link's task and written by nobody else.
private final class FakeEventsSocket: HostEventsSocketing, @unchecked Sendable {
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

    var lastActivity: Date { Date() }

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
private final class FakeSockets: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [FakeEventsSocket]

    init(_ queued: [FakeEventsSocket]) {
        self.queued = queued
    }

    @Sendable
    func make(_ request: URLRequest) -> any HostEventsSocketing {
        lock.withLock { queued.isEmpty ? FakeEventsSocket(.quiet) : queued.removeFirst() }
    }
}
