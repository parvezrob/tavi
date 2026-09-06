import Foundation
@testable import Tavi
import Testing

// The link to one paired computer (#50, #86), driven through a scripted
// socket and a scripted host: every transition the home's header is made
// of — live, stale, revoked, offline — and the repos poll beside it.
@MainActor
struct HostConnectionTests {
    @MainActor
    private final class Events {
        var snapshots: [[AgentSummary]] = []
        var revocations: [String] = []
    }

    private func link(
        sockets: [FakeEventsSocket],
        host: StubHost = StubHost(),
        recovery: RecoveryLog? = nil
    ) throws -> (HostConnection, Events) {
        let factory = FakeSockets(sockets)
        let connection = HostConnection(transport: host.transport, makeSocket: factory.make)
        let events = Events()
        connection.configure(host: try Fixtures.hostEndpoint(), credential: "secret", recovery: recovery) { event in
            switch event {
            case let .snapshot(agents, _, _): events.snapshots.append(agents)
            case let .revoked(reason): events.revocations.append(reason)
            }
        }
        return (connection, events)
    }

    // MARK: - Live

    @Test func theFirstSnapshotMakesTheLinkLive() async throws {
        let (connection, _) = try link(sockets: [FakeEventsSocket(.frame(Fixtures.agentsFrame()), .quiet)])
        defer { connection.stop() }
        try await waitUntil { connection.health == .live }
    }

    @Test func theFirstSnapshotIsHandedToTheDirectory() async throws {
        let (connection, events) = try link(sockets: [FakeEventsSocket(.frame(Fixtures.agentsFrame()), .quiet)])
        defer { connection.stop() }
        try await waitUntil { !events.snapshots.isEmpty }
        #expect(events.snapshots.first?.map(\.id) == ["pane-1"])
    }

    // MARK: - The stream drops

    // PRD §7.8: resume with an explicit stale indicator, never a blank
    // screen — a blocked agent stays visible through reconnects.
    @Test func aDroppedStreamKeepsWhatIsOnScreenAsStale() async throws {
        let (connection, _) = try link(
            sockets: [FakeEventsSocket(.frame(Fixtures.agentsFrame()), .drop)],
            host: StubHost(.json(200, "{}"), .json(200, "{}"))
        )
        defer { connection.stop() }
        try await waitUntil { connection.health == .stale }
    }

    @Test func theReposPollStopsWhileTheStreamIsDown() async throws {
        let (connection, _) = try link(
            sockets: [FakeEventsSocket(.frame(Fixtures.agentsFrame()), .drop)],
            host: StubHost(.json(200, "{}"), .json(200, "{}"))
        )
        defer { connection.stop() }
        try await waitUntil { connection.isPollable == false }
    }

    @Test func theReposPollRunsBesideALiveStream() async throws {
        let (connection, _) = try link(sockets: [FakeEventsSocket(.frame(Fixtures.agentsFrame()), .quiet)])
        defer { connection.stop() }
        try await waitUntil { connection.health == .live }
        #expect(connection.isPollable)
    }

    // The header says how the packets travel, learned from the same probe.
    @Test func theLinkLearnsHowThisPhoneReachesTheComputer() async throws {
        let (connection, _) = try link(
            sockets: [FakeEventsSocket(.frame(Fixtures.agentsFrame()), .drop)],
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
            sockets: [FakeEventsSocket(.frame(Fixtures.agentsFrame()), .drop)],
            host: StubHost(.json(401, #"{"error":"Unauthorized."}"#))
        )
        defer { connection.stop() }
        try await waitUntil { !events.revocations.isEmpty }
    }

    // Retrying cannot fix a dead credential, so the stream stops.
    @Test func aRevokedLinkStopsDialling() async throws {
        let (connection, _) = try link(
            sockets: [FakeEventsSocket(.frame(Fixtures.agentsFrame()), .drop)],
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
                FakeEventsSocket(.frame(Fixtures.agentsFrame()), .quiet),
            ],
            host: StubHost(.silence)
        )
        defer { connection.stop() }
        try await waitUntil(20) { connection.health == .live }
    }

    // MARK: - Leaving

    @Test func closingTheLinkLabelsWhatIsOnScreenStale() async throws {
        let (connection, _) = try link(sockets: [FakeEventsSocket(.frame(Fixtures.agentsFrame()), .quiet)])
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

    // MARK: - The recovery record (#111)

    private func recoveryLog() -> RecoveryLog {
        RecoveryLog(pathObserver: ScriptedPathObserver())
    }

    // The cause is written while the socket that produced it is still the
    // stream's, before the dial closes it.
    @Test func aStreamEndRecordsWhatEndedItAndTheCycleItCaused() async throws {
        let recovery = recoveryLog()
        let (connection, _) = try link(
            sockets: [FakeEventsSocket(.frame(Fixtures.agentsFrame()), .drop)],
            host: StubHost(.json(200, "{}"), .json(200, "{}")),
            recovery: recovery
        )
        defer { connection.stop() }
        try await waitUntil { connection.health == .stale }

        let cause = RecoveryLog.Reason.socket(.urlError, code: URLError.networkConnectionLost.rawValue)
        #expect(recovery.ring.contains { $0.source == .events && $0.kind == .streamEnded && $0.reason == cause })
        #expect(recovery.counters[.events]?.cycles[cause] == 1)
        #expect(recovery.counters[.events]?.dials == 1)
        #expect(recovery.counters[.events]?.readies == 1)
    }

    @Test func aSnapshotAfterADropIsRecordedAsSuch() async throws {
        let recovery = recoveryLog()
        let (connection, _) = try link(
            sockets: [
                FakeEventsSocket(.frame(Fixtures.agentsFrame()), .drop),
                FakeEventsSocket(.frame(Fixtures.agentsFrame()), .quiet),
            ],
            host: StubHost(.json(200, "{}")),
            recovery: recovery
        )
        defer { connection.stop() }
        try await waitUntil(20) { recovery.ring.contains { $0.kind == .snapshotAfterDrop } }
        #expect(connection.health == .live)
    }

    // Offline is a verdict about the computer: both earning it and clearing
    // it are recorded, and the probes that decided it are recorded beside.
    @Test func offlineEarnedAndClearedAreBothRecorded() async throws {
        let recovery = recoveryLog()
        let (connection, _) = try link(
            sockets: [
                FakeEventsSocket(.drop),
                FakeEventsSocket(.drop),
                FakeEventsSocket(.frame(Fixtures.agentsFrame()), .quiet),
            ],
            host: StubHost(.silence),
            recovery: recovery
        )
        defer { connection.stop() }
        try await waitUntil(20) { connection.health == .live }

        #expect(recovery.counters[.events]?.offlineEntered == 1)
        #expect(recovery.counters[.events]?.offlineCleared == 1)
        #expect(recovery.ring.contains { $0.kind == .probe(.unreachable) })
    }

    @Test func aRejectedProbeRecordsTheProbeAndTheRevocation() async throws {
        let recovery = recoveryLog()
        let (connection, events) = try link(
            sockets: [FakeEventsSocket(.frame(Fixtures.agentsFrame()), .drop)],
            host: StubHost(.json(401, #"{"error":"Unauthorized."}"#)),
            recovery: recovery
        )
        defer { connection.stop() }
        try await waitUntil { !events.revocations.isEmpty }

        #expect(recovery.ring.contains { $0.kind == .probe(.rejected) })
        #expect(recovery.ring.contains { $0.kind == .revoked })
    }

    @Test func aReachableProbeIsRecorded() async throws {
        let recovery = recoveryLog()
        let (connection, _) = try link(
            sockets: [FakeEventsSocket(.frame(Fixtures.agentsFrame()), .drop)],
            host: StubHost(.json(200, "{}")),
            recovery: recovery
        )
        defer { connection.stop() }
        try await waitUntil(10) { recovery.ring.contains { $0.kind == .probe(.reachable) } }
    }
}
