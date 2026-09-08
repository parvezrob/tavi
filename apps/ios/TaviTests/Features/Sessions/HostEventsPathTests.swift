import Foundation
@testable import Tavi
import Testing

// What the phone's own network does to the link's verdicts (#111 P2): a path
// that comes back cuts the socket waiting on the old one, and a path that is
// gone withholds a new Offline without unsaying one already earned. The
// probes are the link's real ones, answered by a stub host.
@MainActor
struct HostEventsPathTests {
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
        #expect(scene.events(.cycling).last?.reason == .pathRestored)
        // The redial runs on the wake, not on the schedule: nothing here
        // resumes a retry delay.
        try await waitFor { scene.socket.resumes == 2 }
        #expect(scene.link.isRunning)
        #expect(scene.link.reconnectAttempt == 1)
    }

    // The host closes the socket while a challenge is outstanding, with its
    // send still hanging. One redial follows; the replacement dial is not
    // touched by the dead dial's deadline, and the old send returning after
    // the replacement is live changes nothing. The schedule is the wide one
    // so that resuming the dead dial's 2 s cannot be confused with resuming
    // the delay before the redial.
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
        try await waitForProbe { scene.link.isOffline }

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
            try await waitFor { scene.socket.resumes == index + 1 }
            scene.socket.failReceive(at: scene.now)
            // The pair of questions the link asks a silent computer: the
            // second is 1.5 s behind the first, both waited out on the
            // manual clock. Then the dial's own place in the schedule.
            try await waitForProbe { await scene.clock.hasWaiter(for: .seconds(1.5)) }
            try await scene.clock.resumeAll(for: .seconds(1.5))
            // Both answers are in before the next dial: the link runs one
            // verification per generation, so a dial that failed while the
            // previous pair was still in flight would ask nothing at all.
            try await waitForProbe { scene.events(.probe(.unreachable)).count == (index + 1) * 2 }
            try await releaseRetryDelay(scene, step)
        }
    }
}
