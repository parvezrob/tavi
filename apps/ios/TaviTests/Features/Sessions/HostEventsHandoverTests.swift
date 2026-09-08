import Foundation
@testable import Tavi
import Testing

// The events link on a phone whose network moves (#111 P2): the 2 s check
// after a satisfied→satisfied path change, and what a path that goes and
// comes back may and may not do to the link's verdicts. Every deadline is
// crossed on the manual clock; every pong is a payload the test chooses.
@MainActor
struct HostEventsHandoverTests {
    // The whole point of a payload: a pong proves the round it names.
    private func challenge(_ scene: EventsScene) async throws -> Data {
        await scene.moveTo(EventsScene.cellular)
        try await waitFor { scene.socket.pings == 1 }
        return try #require(scene.socket.challenges.last)
    }

    @Test
    func aPongInsideTheHandoverBudgetPassesAndIsRecorded() async throws {
        let scene = try EventsScene()
        defer { scene.tearDown() }
        try await scene.establish()
        let payload = try await challenge(scene)

        scene.clock.advance(by: .milliseconds(1_900))
        scene.socket.answer(payload, at: scene.now)
        try await waitFor { !scene.events(.handoverChecked).isEmpty }

        // The deadline still runs out; it has nothing left to judge.
        scene.clock.advance(by: .milliseconds(100))
        try await scene.clock.resumeAll(for: HostConnection.handoverDeadline)
        await settle()
        #expect(scene.socket.goingAwayCancels == 0)
        #expect(scene.events(.handoverFailed).isEmpty)
    }

    @Test
    func aPongAfterTheHandoverBudgetCyclesTheSocket() async throws {
        let scene = try EventsScene()
        defer { scene.tearDown() }
        try await scene.establish()
        let payload = try await challenge(scene)

        scene.clock.advance(by: .milliseconds(2_100))
        try await scene.clock.resumeAll(for: HostConnection.handoverDeadline)
        try await waitFor { scene.socket.goingAwayCancels == 1 }
        let failed = try #require(scene.events(.handoverFailed).first)
        #expect(failed.reason == .handover(.pongMissing))
        #expect(scene.events(.cycling).first?.reason == .handover(.pongMissing))

        // The peer's answer, 200 ms late, changes nothing.
        scene.socket.answer(payload, at: scene.now)
        await settle()
        #expect(scene.events(.handoverChecked).isEmpty)
    }

    // The send is owned, not awaited: a ping that never returns is the miss
    // the deadline names, and it happens once (#107's defect).
    @Test
    func aHandoverSendThatNeverReturnsCyclesOnceAsSendStalled() async throws {
        let scene = try EventsScene(pingSuspends: true)
        defer { scene.tearDown() }
        try await scene.establish()
        _ = try await challenge(scene)

        try await scene.clock.resumeAll(for: HostConnection.handoverDeadline)
        try await waitFor { scene.socket.goingAwayCancels == 1 }
        #expect(scene.events(.handoverFailed).first?.reason == .handover(.sendStalled))

        await settle()
        #expect(scene.socket.goingAwayCancels == 1)
        #expect(scene.events(.handoverFailed).count == 1)
    }

    // A dial that has not delivered a frame is not established: it keeps its
    // own budget, and nothing is challenged on a socket that has said nothing.
    @Test
    func aPathChangeDuringADialInProgressLeavesItsBudgetAlone() async throws {
        let scene = try EventsScene()
        defer { scene.tearDown() }
        try await waitFor { scene.socket.resumes == 1 }

        await scene.moveTo(EventsScene.wifi)
        await scene.moveTo(EventsScene.cellular)

        #expect(scene.socket.pings == 0)
        #expect(scene.socket.goingAwayCancels == 0)
        #expect(await scene.clock.timesScheduled(EventsLinkDefaults.schedule.connectDeadline) == 1)
    }

    // Coalesced: the earliest deadline decides, and a path that flaps while
    // one challenge is outstanding does not start another or move it.
    @Test
    func aFlappingPathIsOneChallengeOnItsOriginalDeadline() async throws {
        let scene = try EventsScene()
        defer { scene.tearDown() }
        try await scene.establish()
        _ = try await challenge(scene)

        scene.clock.advance(by: .milliseconds(1_500))
        await scene.moveTo(EventsScene.otherWiFi)
        scene.clock.advance(by: .milliseconds(1_500))
        await scene.moveTo(EventsScene.wifi)

        #expect(scene.socket.pings == 1)
        #expect(await scene.clock.timesScheduled(HostConnection.handoverDeadline) == 1)
        try await scene.clock.resumeAll(for: HostConnection.handoverDeadline)
        try await waitFor { scene.socket.goingAwayCancels == 1 }
        #expect(scene.events(.handoverFailed).count == 1)
    }

    // A pong for the watchdog's earlier ping is not this challenge's answer:
    // the payloads differ, and the socket is cycled on time.
    @Test
    func aWatchdogPongDoesNotAnswerTheHandoverChallenge() async throws {
        let scene = try EventsScene()
        defer { scene.tearDown() }
        try await scene.establish()

        scene.clock.advance(by: .seconds(21))
        try await pollWatchdog(scene.clock)
        try await waitFor { scene.socket.pings == 1 }
        let watchdogPayload = try #require(scene.socket.challenges.first)

        await scene.moveTo(EventsScene.cellular)
        try await waitFor { scene.socket.pings == 2 }
        scene.socket.answer(watchdogPayload, at: scene.now)
        await settle()
        #expect(scene.events(.handoverChecked).isEmpty)

        try await scene.clock.resumeAll(for: HostConnection.handoverDeadline)
        try await waitFor { scene.socket.goingAwayCancels == 1 }
        #expect(scene.events(.handoverFailed).first?.reason == .handover(.pongMissing))
    }

    // The host's own 15 s ping moves the idle clock the watchdog reads. It
    // says nothing about whether this socket can still reach the host on the
    // new interface, so it cannot stand in for the pong.
    @Test
    func aServerPingAdvancingTheIdleClockDoesNotSatisfyAChallenge() async throws {
        let scene = try EventsScene()
        defer { scene.tearDown() }
        try await scene.establish()
        _ = try await challenge(scene)

        scene.clock.advance(by: .seconds(1))
        scene.socket.arrive(at: scene.now)
        try await scene.clock.resumeAll(for: HostConnection.handoverDeadline)
        try await waitFor { scene.socket.goingAwayCancels == 1 }
        #expect(scene.events(.handoverChecked).isEmpty)
        #expect(scene.events(.handoverFailed).first?.reason == .handover(.pongMissing))
    }

    // A network that comes back is a real signal: cut the socket that is
    // waiting on the path that is gone and dial now, without pretending this
    // is a fresh start — the attempt count and the epoch are the outage's.
    @Test
    func aRestoredPathCyclesTheRetainedSocketAndDialsNow() async throws {
        let scene = try EventsScene()
        defer { scene.tearDown() }
        try await scene.establish()

        await scene.moveTo(EventsScene.noPath)
        #expect(scene.link.isStale)
        await scene.moveTo(EventsScene.wifi)

        try await waitFor { scene.socket.goingAwayCancels == 1 }
        // The redial runs on the wake, not on the schedule: nothing here
        // resumes a retry delay.
        try await waitFor { scene.socket.resumes == 2 }
        #expect(scene.link.isRunning)
        #expect(scene.link.reconnectAttempt == 1)
    }

    // With no path of its own the phone knows nothing about the computer, so
    // two unanswered questions are about the phone, not about the Mac.
    @Test
    func anUnsatisfiedPathWithholdsANewOfflineVerdict() async throws {
        let scene = try EventsScene()
        defer { scene.tearDown() }
        await scene.moveTo(EventsScene.noPath)

        try await failTwoDials(scene)
        #expect(scene.link.isOffline == false)
        #expect(scene.events(.offlineEntered).isEmpty)
        #expect(scene.link.health == .connecting)
    }

    // An Offline already earned is a fact about the computer; losing the
    // path afterwards does not unsay it.
    @Test
    func anEarnedOfflineIsNotMaskedByAPathLoss() async throws {
        let scene = try EventsScene()
        defer { scene.tearDown() }

        try await failTwoDials(scene)
        try await waitForAnswer { scene.link.isOffline }

        await scene.moveTo(EventsScene.noPath)
        #expect(scene.link.isOffline)
        #expect(scene.events(.offlineCleared).isEmpty)
    }

    // A 401 is definitive whatever the phone's network is doing.
    @Test
    func aRejectionRevokesEvenWithNoPath() async throws {
        let scene = try EventsScene(host: StubHost(routing: ["GET /api/host": .json(401, "{}")]))
        defer { scene.tearDown() }
        await scene.moveTo(EventsScene.noPath)

        scene.socket.failReceive(at: scene.now)
        try await waitFor { scene.link.isRevoked }
        #expect(scene.link.health == .revoked)
    }

    // Two dials that produced no frame, each followed by the pair of
    // questions the link asks a silent computer — everything Offline needs
    // except a path to have asked over.
    private func failTwoDials(_ scene: EventsScene) async throws {
        let steps = [EventsLinkDefaults.firstDelay, EventsLinkDefaults.secondDelay]
        for (index, step) in steps.enumerated() {
            try await waitForAnswer { scene.socket.resumes == index + 1 }
            scene.socket.failReceive(at: scene.now)
            // The pair of questions the link asks a silent computer: the
            // second is 1.5 s behind the first, both waited out on the
            // manual clock. Then the dial's own place in the schedule.
            try await waitForAnswer { await scene.clock.hasWaiter(for: .seconds(1.5)) }
            try await scene.clock.resumeAll(for: .seconds(1.5))
            try await waitForAnswer { await scene.clock.hasWaiter(within: step) }
            try await scene.clock.resumeAll(within: step)
        }
    }
}
