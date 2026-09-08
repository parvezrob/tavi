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
    func aCloseMidChallengeRedialsOnceAndLeavesTheReplacementAlone() async throws {
        let scene = try EventsScene(pingSuspends: true, schedule: EventsLinkDefaults.wideSchedule)
        defer { scene.tearDown() }
        try await scene.establish()
        _ = try await challenge(scene)

        scene.socket.failReceive(at: scene.now)
        try await releaseRetryDelay(scene, EventsLinkDefaults.wideFirstDelay)
        try await waitFor { scene.socket.resumes == 2 }
        scene.socket.deliver(Fixtures.agentsFrame(), at: scene.now)
        try await waitFor { scene.link.isStale == false }

        // The dead dial's 2 s, and its send, both land after the fact.
        scene.clock.advance(by: .seconds(3))
        try? await scene.clock.resumeAll(for: HostConnection.handoverDeadline)
        scene.socket.releasePings()
        await settle()

        #expect(scene.socket.resumes == 2)
        #expect(scene.socket.goingAwayCancels == 0)
        #expect(scene.events(.handoverFailed).isEmpty)
        #expect(scene.events(.handoverChecked).isEmpty)
    }

    // Stopping is the link letting go of everything it owns, a challenge in
    // flight included: nothing it started may still fire afterwards.
    @Test
    func aStopDuringAChallengeLetsNothingFireAfterwards() async throws {
        let scene = try EventsScene(pingSuspends: true)
        defer { scene.tearDown() }
        try await scene.establish()
        _ = try await challenge(scene)

        scene.link.stop()
        let cancelsAtStop = scene.socket.goingAwayCancels
        let recorded = scene.recovery.ring.count

        scene.clock.advance(by: .seconds(3))
        try? await scene.clock.resumeAll(for: HostConnection.handoverDeadline)
        scene.socket.releasePings()
        await settle()

        #expect(scene.socket.goingAwayCancels == cancelsAtStop)
        #expect(scene.recovery.ring.count == recorded)
        #expect(scene.events(.handoverFailed).isEmpty)
        #expect(scene.events(.handoverChecked).isEmpty)
    }

    // With no path of its own the phone knows nothing about the computer, so
    // two unanswered questions are about the phone, not about the Mac.
    // The invariant every identity check in the link rests on, and the one a
    // single shared double quietly broke: a superseded dial must hold an
    // object its replacement never uses, or the dial that unwinds last takes
    // the live dial's socket with it (#111 — this suite was intermittent for
    // exactly that reason).
    @Test
    func everyDialIsHandedItsOwnSocketObject() async throws {
        let scene = try EventsScene()
        defer { scene.tearDown() }
        let request = URLRequest(url: try #require(URL(string: "wss://studio.tailnet.ts.net/events")))

        let first = scene.link.makeSocket(request)
        let second = scene.link.makeSocket(request)
        #expect(first !== second)
    }

    // The contract's ownership rule: one challenge owns one send, and only
    // the socket's cancellation ends a send that never returns. A pong that
    // answers the challenge does not release it, so the next path change
    // cannot start a second ping on the same socket.
    @Test
    func aChallengeAnsweredWhileItsSendHangsRefusesTheNextUntilTheSocketEndsIt() async throws {
        let scene = try EventsScene(pingSuspends: true)
        defer { scene.tearDown() }
        try await scene.establish()
        let payload = try await challenge(scene)

        scene.clock.advance(by: .seconds(1))
        scene.socket.answer(payload, at: scene.now)
        try await waitFor { !scene.events(.handoverChecked).isEmpty }
        scene.clock.advance(by: .seconds(1))
        try await scene.clock.resumeAll(for: HostConnection.handoverDeadline)
        await settle()

        // The interface moves again while that first send is still in flight.
        await scene.moveTo(EventsScene.otherWiFi)
        #expect(scene.socket.pings == 1)
        #expect(scene.events(.handoverFailed).isEmpty)

        // Cancelling the socket is what ends it, and nothing was orphaned.
        scene.link.stop()
        scene.socket.releasePings()
        await settle()
        #expect(scene.socket.pings == 1)
    }

    // A pong read after the budget is a miss even though the bound task has
    // not run yet: the deadline is the clock's, not the scheduler's.
    @Test
    func aPongPastTheDeadlineInstantIsAMissBeforeTheBoundEvenFires() async throws {
        let scene = try EventsScene()
        defer { scene.tearDown() }
        try await scene.establish()
        let payload = try await challenge(scene)

        scene.clock.advance(by: .milliseconds(2_100))
        scene.socket.answer(payload, at: scene.now)
        await settle()
        #expect(scene.events(.handoverChecked).isEmpty)

        try await scene.clock.resumeAll(for: HostConnection.handoverDeadline)
        try await waitFor { scene.socket.goingAwayCancels == 1 }
        #expect(scene.events(.handoverFailed).first?.reason == .handover(.pongMissing))
    }

    // A foreground restart dials again on the same link. The replacement is
    // not established until it has delivered a frame of its own, so a path
    // change during its upgrade must not cut it at 2 s — the dial's own 15 s
    // is the only budget it is under (#111).
    @Test
    func aRestartedLinkIsNotEstablishedUntilItsNewDialDeliversAFrame() async throws {
        let scene = try EventsScene()
        defer { scene.tearDown() }
        try await scene.establish()

        scene.link.stop()
        scene.link.start()
        try await waitFor { scene.socket.resumes == 2 }

        // The replacement has delivered nothing yet, so a path change finds
        // nothing established to challenge. (The challenge is asked for by
        // hand: a scripted path stream has one consumer, and the watch this
        // link restarted is a second.)
        scene.link.challengeHandover()
        await settle()
        #expect(scene.socket.pings == 0)
        #expect(scene.link.streamConnectedAt == nil)
        #expect(await scene.clock.timesScheduled(HostConnection.handoverDeadline) == 0)

        // Its own first frame is what makes it established — and `hasLoaded`
        // is no barrier here, since the previous dial had already set it.
        scene.socket.deliver(Fixtures.agentsFrame(), at: scene.now)
        try await waitFor { scene.link.streamConnectedAt != nil }
        scene.link.challengeHandover()
        try await waitFor { scene.socket.pings == 1 }
    }

    // Reconfiguring is `stop()` and `start()` on one turn, so the replacement
    // dial is under way while the old one is still parked in `receive()`:
    // when that dial finally unwinds, its defer's `self.socket === socket`
    // guard fails and it lets go of nothing. `stop()` is therefore the only
    // owner that can have released the challenge — and if it does not, the
    // slot stays occupied and the replacement can never challenge at all.
    @Test
    func aStopDuringAChallengeFreesTheNextDialToChallengeAgain() async throws {
        let scene = try EventsScene(pingSuspends: true, ignoresCancel: true)
        defer { scene.tearDown() }
        try await scene.establish()
        _ = try await challenge(scene)

        scene.link.configure(
            host: try Fixtures.hostEndpoint(),
            credential: "secret",
            recovery: scene.recovery
        ) { _ in }
        // Read on the same turn, before any defer, deadline or dial has had
        // one: `stop()` is the only thing that has run, so the slot it left
        // is the slot it chose to leave.
        #expect(scene.link.handover == nil)
        #expect(scene.link.handoverSend == nil)

        // The old dial unwinds behind the replacement, which delivers its own
        // frame and is challenged in its own right; the old send returning
        // late changes nothing.
        scene.socket.releaseReceives()
        try await waitFor { scene.socket.resumes == 2 }
        scene.socket.deliver(Fixtures.agentsFrame(), at: scene.now)
        try await waitFor { scene.link.hasLoaded }
        scene.socket.releasePings()
        await settle()
        scene.link.challengeHandover()
        try await waitFor { scene.socket.pings == 2 }
    }
}
