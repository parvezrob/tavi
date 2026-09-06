import Foundation
@testable import Tavi
import Testing

// Probe, configuration and stream lifetime on the events link (#108). A probe
// outlives the dial that started it, so every test asks the same question:
// what is an answer from a computer this link has left behind allowed to do —
// and what must still be believed? Answers are released by hand and dials are
// held open by hand.
@MainActor
struct HostConnectionProbeTests {
    // MARK: - After the link is stopped

    // `stop()` cannot recall a request already with the network.
    @Test func aComputersAnswerReleasedAfterStopDescribesNoLink() async throws {
        let host = GatedHost()
        let sockets = HeldEventsSockets(HeldEventsSocket(.frame(Fixtures.agentsFrame()), .drop))
        let (connection, _) = try probeLink(sockets, host: host)
        defer { host.releaseAll(); sockets.releaseHolds() }

        try await waitUntil { connection.isStale && host.callsWaiting == 1 }
        connection.stop()

        host.release(.json(200, #"{"connection":{"path":"relay","relay":"blr"}}"#))
        try await waitUntil { host.callsFinished == 1 }
        await drainProbes()

        #expect(connection.path == .unknown)
        #expect(connection.latencyMilliseconds == nil)
    }

    // Released after `stop()`, a 401 would revoke a pairing nobody asked about.
    @Test func aRejectionReleasedAfterStopRevokesNothing() async throws {
        let host = GatedHost()
        let sockets = HeldEventsSockets(HeldEventsSocket(.frame(Fixtures.agentsFrame()), .drop))
        let (connection, events) = try probeLink(sockets, host: host)
        defer { host.releaseAll(); sockets.releaseHolds() }

        try await waitUntil { connection.isStale && host.callsWaiting == 1 }
        connection.stop()

        host.release(.json(401, #"{"error":"Unauthorized."}"#))
        try await waitUntil { host.callsFinished == 1 }
        await drainProbes()

        #expect(events.revocations.isEmpty)
        #expect(connection.isRevoked == false)
        #expect(connection.health == .stale)
    }

    // Stopped while the verification is on its deciding question.
    @Test func anUnansweredComputerReleasedAfterStopDoesNotSayOffline() async throws {
        let host = GatedHost(script: [.silence])
        let sockets = HeldEventsSockets(HeldEventsSocket(.drop), HeldEventsSocket(.drop))
        let (connection, _) = try probeLink(sockets, host: host, policy: ProbeSchedule.oneRedial)
        defer { host.releaseAll(); sockets.releaseHolds() }

        try await waitUntil(4) { sockets.dials == 2 && host.callsWaiting == 1 && host.callsStarted == 2 }
        connection.stop()

        host.release(.silence)
        try await waitUntil { host.callsFinished == 2 }
        await drainProbes()

        #expect(connection.isOffline == false)
    }

    // MARK: - After the link is pointed at another computer

    @Test func aRejectionReleasedAfterReconfiguringDoesNotRevokeTheNewComputer() async throws {
        let host = GatedHost()
        let sockets = HeldEventsSockets(
            HeldEventsSocket(.frame(Fixtures.agentsFrame()), .drop),
            HeldEventsSocket(.hold),
            HeldEventsSocket(.frame(Fixtures.agentsFrame()), .hold)
        )
        let (connection, events) = try probeLink(sockets, host: host)
        defer { connection.stop(); host.releaseAll(); sockets.releaseHolds() }

        try await waitUntil { connection.isStale && host.callsWaiting == 1 }
        try probeReconfigure(connection, into: events)
        try await waitUntil { connection.health == .live }

        host.release(.json(401, #"{"error":"Unauthorized."}"#))
        try await waitUntil { host.callsFinished == 1 }
        await drainProbes()

        #expect(events.revocations.isEmpty)
        #expect(connection.health == .live)
        #expect(connection.isRunning)
    }

    // `path` is the computer's own account of itself; one that is no longer
    // configured may not write it.
    @Test func aComputersAnswerReleasedAfterReconfiguringDescribesNeither() async throws {
        let host = GatedHost()
        let sockets = HeldEventsSockets(
            HeldEventsSocket(.frame(Fixtures.agentsFrame()), .drop),
            HeldEventsSocket(.hold),
            HeldEventsSocket(.frame(Fixtures.agentsFrame()), .hold)
        )
        let (connection, events) = try probeLink(sockets, host: host)
        defer { connection.stop(); host.releaseAll(); sockets.releaseHolds() }

        try await waitUntil { connection.isStale && host.callsWaiting == 1 }
        try probeReconfigure(connection, into: events)
        try await waitUntil { connection.health == .live }

        host.release(.json(200, #"{"connection":{"path":"relay","relay":"blr"}}"#))
        try await waitUntil { host.callsFinished == 1 }
        await drainProbes()

        #expect(connection.path == .unknown)
    }

    // The header would otherwise show the previous computer's relay sentence as
    // current fact until the new one answers.
    @Test func pointingTheLinkAtAnotherComputerForgetsTheOldPath() async throws {
        let host = GatedHost(script: [.json(200, #"{"connection":{"path":"relay","relay":"blr"}}"#)])
        let sockets = HeldEventsSockets(
            HeldEventsSocket(.frame(Fixtures.agentsFrame()), .hold),
            HeldEventsSocket(.hold)
        )
        let (connection, events) = try probeLink(sockets, host: host, policy: ProbeSchedule.singleDial)
        defer { connection.stop(); host.releaseAll(); sockets.releaseHolds() }

        try await waitUntil { connection.path == .relay("blr") }
        try probeReconfigure(connection, into: events)

        #expect(connection.path == .unknown)
    }

    // The old verification is still out while the link moves to another
    // computer that is itself in trouble — where a borrowed verdict is believed.
    @Test func anUnansweredComputerReleasedAfterReconfiguringDoesNotSayOffline() async throws {
        let host = GatedHost()
        let sockets = HeldEventsSockets(
            HeldEventsSocket(.drop),
            HeldEventsSocket(.hold),
            HeldEventsSocket(.drop),
            HeldEventsSocket(.drop)
        )
        let (connection, events) = try probeLink(sockets, host: host, policy: ProbeSchedule.oneRedial)
        defer { connection.stop(); host.releaseAll(); sockets.releaseHolds() }

        try await waitUntil { sockets.dials == 2 && host.callsWaiting == 1 }
        try probeReconfigure(connection, into: events)
        // The new computer misses twice too, so its own accounting allows
        // Offline and only the fence says whose verdict this is.
        try await waitUntil { sockets.dials == 4 && connection.isStale }
        await drainProbes()
        // One verification per configuration, not one per failed dial.
        #expect(host.callsWaiting == 2)

        host.release(.silence)
        try await waitUntil { host.callsFinished == 1 }
        await drainProbes()

        #expect(connection.isOffline == false)
        #expect(host.callsWaiting == 1)
    }

    // MARK: - After the socket is replaced on the same computer

    @Test func aRejectionFromAReplacedSocketCannotRevokeALiveStream() async throws {
        let host = GatedHost()
        let sockets = HeldEventsSockets(
            HeldEventsSocket(.drop),
            HeldEventsSocket(.frame(Fixtures.agentsFrame()), .hold)
        )
        let (connection, events) = try probeLink(sockets, host: host)
        defer { connection.stop(); host.releaseAll(); sockets.releaseHolds() }

        // The redial lands a snapshot while the old probe is still out, and
        // puts its own question rather than joining it.
        try await waitUntil { connection.health == .live && host.callsWaiting == 2 }

        host.release(.json(401, #"{"error":"Unauthorized."}"#))
        try await waitUntil { host.callsFinished == 1 }
        await drainProbes()

        #expect(events.revocations.isEmpty)
        #expect(connection.health == .live)
        #expect(connection.isRunning)
        #expect(host.callsWaiting == 1)
    }

    // A held dial unwinding late must not hand the directory a snapshot from a
    // computer the phone has stopped looking at.
    @Test func aFrameFromAReplacedSocketNeverReachesTheDirectory() async throws {
        let host = GatedHost()
        let replaced = HeldEventsSocket(.hold, .frame(Fixtures.agentsFrame(status: "blocked")))
        let sockets = HeldEventsSockets(
            replaced,
            HeldEventsSocket(.frame(Fixtures.agentsFrame(status: "working")), .hold)
        )
        let (connection, events) = try probeLink(sockets, host: host)
        defer { connection.stop(); host.releaseAll(); sockets.releaseHolds() }

        try await waitUntil { sockets.dials == 1 }
        try probeReconfigure(connection, into: events)
        try await waitUntil { connection.health == .live }

        // Closing is the last thing the old dial does: by then its frame has
        // been through the link, or been turned away at it.
        replaced.releaseHolds()
        try await waitUntil { replaced.normalCloses == 1 }
        await drainProbes()

        #expect(events.snapshots.count == 1)
        #expect(events.snapshots.first?.first?.status == "working")
        #expect(connection.health == .live)
    }

    // A cancelled dial still runs its `defer`, by which time another computer
    // may be in place; one borrowed miss is Reconnecting versus Offline.
    @Test func aReplacedDialsAccountingDoesNotCountAgainstTheNewComputer() async throws {
        let host = GatedHost(script: [.silence])
        let stalled = HeldEventsSocket(.hold)
        let sockets = HeldEventsSockets(stalled, HeldEventsSocket(.drop))
        let (connection, events) = try probeLink(sockets, host: host, policy: ProbeSchedule.singleDial)
        defer { connection.stop(); host.releaseAll(); sockets.releaseHolds() }

        try await waitUntil { sockets.dials == 1 }
        try probeReconfigure(connection, into: events)
        // The new computer has missed once, and is a moment from the question
        // that would make Offline earned at two.
        try await waitUntil(4) { host.callsWaiting == 1 && host.callsStarted == 2 }

        stalled.releaseHolds()
        try await waitUntil { stalled.normalCloses == 1 }

        host.release(.silence)
        try await waitUntil { host.callsFinished == 2 }
        await drainProbes()

        #expect(connection.isOffline == false)
    }

    // MARK: - Earning Offline across failed redials

    // A computer that black-holes answers neither question inside one dial: the
    // redial lands between them. The verdict belongs to the reachability
    // generation, so a failed redial neither throws it away nor restarts it.
    @Test func twoUnansweredQuestionsSpanningAFailedRedialEarnOffline() async throws {
        let host = GatedHost(script: [.silence])
        let sockets = HeldEventsSockets(HeldEventsSocket(.drop), HeldEventsSocket(.drop))
        let (connection, _) = try probeLink(sockets, host: host, policy: ProbeSchedule.oneRedial)
        defer { connection.stop(); host.releaseAll(); sockets.releaseHolds() }

        // The redial has already failed and been counted while the first
        // question was out, and asked nothing of its own.
        try await waitUntil(4) { sockets.dials == 2 && host.callsWaiting == 1 && host.callsStarted == 2 }

        host.release(.silence)
        try await waitUntil { connection.health == .offline }
        #expect(connection.isOffline)
    }

    // A request the link itself cancelled — the verification's held second
    // question, displaced when a later failed dial's connect deadline asks
    // under its own epoch — is not an answer about the computer: counting it
    // earned Offline from one timeout plus one cancellation (#108).
    @Test func aDisplacedQuestionIsNotCountedAsAMiss() async throws {
        let host = GatedHost(script: [.silence], cancellable: true)
        let sockets = HeldEventsSockets(
            HeldEventsSocket(.drop),
            HeldEventsSocket(.drop),
            HeldEventsSocket(.hold)
        )
        let (connection, _) = try probeLink(sockets, host: host, policy: ProbeSchedule.lateRedial)
        defer { connection.stop(); host.releaseAll(); sockets.releaseHolds() }

        // The first question was a genuine miss; the second is out when the
        // third dial's deadline displaces it.
        try await waitUntil(6) { host.callsCancelled == 1 && host.callsWaiting == 1 }
        await drainProbes()
        #expect(connection.isOffline == false)

        // Only a second genuine miss earns it.
        host.release(.silence)
        try await waitUntil { connection.health == .offline }
        #expect(host.callsCancelled == 1)
    }

    // The other bound: a stream that actually spoke settles the question, even
    // if it drops again straight after and further dials fail.
    @Test func aVerdictFromBeforeALiveSnapshotCannotSayOffline() async throws {
        let host = GatedHost()
        let sockets = HeldEventsSockets(
            HeldEventsSocket(.drop),
            HeldEventsSocket(.frame(Fixtures.agentsFrame()), .drop),
            HeldEventsSocket(.drop),
            HeldEventsSocket(.drop)
        )
        let (connection, _) = try probeLink(sockets, host: host)
        defer { connection.stop(); host.releaseAll(); sockets.releaseHolds() }

        // One verification from before the snapshot and one from after; the
        // two further failed dials start neither.
        try await waitUntil { sockets.dials == 5 && host.callsWaiting == 2 }
        #expect(connection.isStale)

        host.release(.silence)
        try await waitUntil { host.callsFinished == 1 }
        await drainProbes()

        #expect(connection.isOffline == false)
        #expect(host.callsWaiting == 1)
    }

    // MARK: - The probes the link owns

    // A socket that never answers keeps `streamOnce` suspended, so nothing but
    // the link itself can end the deadline's probe.
    @Test func aConnectDeadlineProbeReleasedAfterStopDoesNotSayOffline() async throws {
        let host = GatedHost(script: [.json(200, "{}"), .silence])
        let sockets = HeldEventsSockets(HeldEventsSocket(.drop), HeldEventsSocket(.hold))
        let (connection, _) = try probeLink(sockets, host: host, policy: ProbeSchedule.quickDeadline)
        defer { host.releaseAll(); sockets.releaseHolds() }

        // One dial has already produced no frame, which is what lets the
        // deadline's probe say Offline at all.
        try await waitUntil(4) { host.callsWaiting == 1 && host.callsStarted == 3 }
        connection.stop()

        host.release(.silence)
        try await waitUntil { host.callsFinished == 3 }
        await drainProbes()

        #expect(connection.isOffline == false)
    }

    // Single flight within one epoch: the first frame's round trip and the drop
    // behind it are two askers and one `GET /api/host`.
    @Test func twoAskersInOneEpochProduceOneQuestion() async throws {
        let host = GatedHost()
        let sockets = HeldEventsSockets(HeldEventsSocket(.frame(Fixtures.agentsFrame()), .drop))
        let (connection, _) = try probeLink(sockets, host: host, policy: ProbeSchedule.singleDial)
        defer { connection.stop(); host.releaseAll(); sockets.releaseHolds() }

        try await waitUntil { connection.isStale && host.callsWaiting == 1 }
        await drainProbes()
        #expect(host.callsStarted == 1)

        host.release(.json(200, "{}"))
        try await waitUntil { connection.latencyMilliseconds != nil }
        #expect(host.callsStarted == 1)
    }

    // MARK: - An answer that predates the stream reading it

    // The number the header shows belongs to the dial that measured it. A new
    // stream puts its own question rather than joining one already out: joining
    // applies an older answer under the newer stream's name, where every
    // caller-side fence passes it.
    @Test func aRedialsOwnMeasurementIsWhatTheHeaderShows() async throws {
        let host = GatedHost()
        let sockets = HeldEventsSockets(
            HeldEventsSocket(.frame(Fixtures.agentsFrame()), .drop),
            HeldEventsSocket(.frame(Fixtures.agentsFrame()), .hold)
        )
        let (connection, _) = try probeLink(sockets, host: host)
        defer { connection.stop(); host.releaseAll(); sockets.releaseHolds() }

        try await waitUntil { connection.health == .live && host.callsWaiting == 2 }

        host.release(.json(200, #"{"connection":{"path":"relay","relay":"blr"}}"#))
        try await waitUntil { host.callsFinished == 1 }
        await drainProbes()
        #expect(connection.path == .unknown)
        #expect(connection.latencyMilliseconds == nil)

        host.release(.json(200, #"{"connection":{"path":"direct"}}"#))
        try await waitUntil { connection.latencyMilliseconds != nil }
        #expect(connection.path == .direct)
    }

    @Test func anOldStreamsUnansweredProbeCannotUnliveANewerStream() async throws {
        let host = GatedHost()
        let sockets = HeldEventsSockets(
            HeldEventsSocket(.drop),
            HeldEventsSocket(.frame(Fixtures.agentsFrame()), .hold)
        )
        let (connection, _) = try probeLink(sockets, host: host)
        defer { connection.stop(); host.releaseAll(); sockets.releaseHolds() }

        try await waitUntil { connection.health == .live && host.callsWaiting == 2 }

        host.release(.silence)
        try await waitUntil { host.callsFinished == 1 }
        await drainProbes()

        #expect(connection.isOffline == false)
        #expect(connection.health == .live)
        // And it does not ask its second question on the live stream's behalf.
        #expect(host.callsStarted == 2)
        #expect(host.callsWaiting == 1)
    }
}
