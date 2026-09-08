import Foundation
@testable import Tavi
import Testing

// What a dial has to show for itself (#111 P2): frames delivered across the
// stable interval before the backoff forgets the attempts behind it, and a
// first agents frame inside 15 s of the dial's start. Which step of the
// schedule the link is sitting out is how these read its attempt count.
@MainActor
struct HostEventsLivenessTests {
    // A first dial that produced nothing, so the schedule is past its first
    // step and a reset is visible as a return to it.
    private func afterOneFailedDial(_ scene: EventsScene) async throws {
        try await waitFor { scene.socket.resumes == 1 }
        scene.socket.failReceive(at: scene.now)
        try await waitFor { await scene.clock.hasWaiter(within: EventsLinkDefaults.firstDelay) }
        try await scene.clock.resumeAll(within: EventsLinkDefaults.firstDelay)
        try await waitFor { scene.socket.resumes == 2 }
    }

    private func snapshot(_ scene: EventsScene) async throws {
        scene.socket.deliver(Fixtures.agentsFrame(), at: scene.now)
        try await waitFor { scene.link.hasLoaded }
    }

    // Frames spanning the stable interval — the host's own pings count — are
    // what a link that was really up looks like.
    @Test
    func aStreamAliveAcrossThirtySecondsResetsTheBackoff() async throws {
        let scene = try EventsScene()
        defer { scene.tearDown() }
        try await afterOneFailedDial(scene)
        try await snapshot(scene)

        scene.clock.advance(by: .seconds(30))
        scene.socket.arrive(at: scene.now)
        scene.socket.failReceive(at: scene.now)

        try await waitFor { await scene.clock.hasWaiter(within: EventsLinkDefaults.firstDelay) }
        #expect(await scene.clock.hasWaiter(within: EventsLinkDefaults.secondDelay) == false)
    }

    @Test
    func aStreamAliveForTwentyNineSecondsDoesNot() async throws {
        let scene = try EventsScene()
        defer { scene.tearDown() }
        try await afterOneFailedDial(scene)
        try await snapshot(scene)

        scene.clock.advance(by: .seconds(29))
        scene.socket.arrive(at: scene.now)
        scene.socket.failReceive(at: scene.now)

        try await waitFor { await scene.clock.hasWaiter(within: EventsLinkDefaults.secondDelay) }
        #expect(await scene.clock.hasWaiter(within: EventsLinkDefaults.firstDelay) == false)
    }

    // One snapshot and then silence is exactly the blackhole the watchdog
    // cuts. Time passed; nothing was delivered; the backoff remembers.
    @Test
    func aSnapshotThenSilenceUntilTheWatchdogCyclesDoesNot() async throws {
        let scene = try EventsScene()
        defer { scene.tearDown() }
        try await afterOneFailedDial(scene)
        try await snapshot(scene)

        scene.clock.advance(by: .seconds(40))
        try await releaseWatchdogPoll(scene.clock)

        try await waitFor { await scene.clock.hasWaiter(within: EventsLinkDefaults.secondDelay) }
        #expect(scene.events(.cycling).contains { $0.reason == .watchdog })
    }

    // The receive error that ends a dial moves `lastActivity` before it
    // throws; `lastFrameAt` is what says whether the peer ever spoke.
    @Test
    func aSnapshotThenAReceiveErrorAtThirtyOneSecondsDoesNot() async throws {
        let scene = try EventsScene()
        defer { scene.tearDown() }
        try await afterOneFailedDial(scene)
        try await snapshot(scene)

        scene.clock.advance(by: .seconds(31))
        scene.socket.failReceive(at: scene.now)

        try await waitFor { await scene.clock.hasWaiter(within: EventsLinkDefaults.secondDelay) }
        #expect(await scene.clock.hasWaiter(within: EventsLinkDefaults.firstDelay) == false)
    }

    // A computer that accepts a dial, says one thing and goes quiet, over
    // and over, must not keep the phone dialling it every two seconds.
    @Test
    func repeatedSingleSnapshotBlackholesKeepTheAttemptClimbing() async throws {
        let scene = try EventsScene()
        defer { scene.tearDown() }
        let steps = [EventsLinkDefaults.firstDelay, EventsLinkDefaults.secondDelay, EventsLinkDefaults.thirdDelay]

        for (index, step) in steps.enumerated() {
            try await waitFor { scene.socket.resumes == index + 1 }
            try await snapshot(scene)
            scene.clock.advance(by: .seconds(40))
            scene.socket.failReceive(at: scene.now)
            try await waitFor { await scene.clock.hasWaiter(within: step) }
            try await scene.clock.resumeAll(within: step)
        }
    }

    // The 2026-09-08 finding: a host that withholds the upgrade answer, or
    // answers it and then says nothing, used to hold a dial until the 45 s
    // watchdog — one frameless dial per two-minute outage, so Offline was
    // never earned. The budget is absolute from dial start.
    @Test
    func aDialThatOnlyEverPingsIsCutAtItsFirstFrameDeadline() async throws {
        let scene = try EventsScene(schedule: EventsLinkDefaults.probing)
        defer { scene.tearDown() }

        try await waitFor { await scene.clock.hasWaiter(for: EventsLinkDefaults.probing.connectDeadline) }
        scene.clock.advance(by: .seconds(5))
        try await scene.clock.resumeAll(for: EventsLinkDefaults.probing.connectDeadline)

        // The rest of the 15 s, and control frames do not extend it.
        try await waitFor { await scene.clock.hasWaiter(for: .seconds(10)) }
        scene.clock.advance(by: .seconds(5))
        scene.socket.arrive(at: scene.now)
        scene.clock.advance(by: .seconds(5))
        try await scene.clock.resumeAll(for: .seconds(10))

        try await waitFor { scene.socket.goingAwayCancels == 1 }
        #expect(scene.events(.firstFrameDeadline).count == 1)
        #expect(scene.events(.cycling).first?.reason == .firstFrameDeadline)
        // And the ordinary schedule takes it from there.
        try await waitFor { await scene.clock.hasWaiter(within: EventsLinkDefaults.firstDelay) }
    }

    // The close-mid-await leg: the socket goes while the 15 s arm is still
    // pending. The arm belongs to the dial that armed it, so the replacement
    // is dialled, established, and left alone by it.
    @Test
    func aCloseWhileTheFirstFrameArmIsPendingLeavesTheReplacementAlone() async throws {
        let scene = try EventsScene(schedule: EventsLinkDefaults.probing)
        defer { scene.tearDown() }

        try await waitFor { await scene.clock.hasWaiter(for: EventsLinkDefaults.probing.connectDeadline) }
        scene.clock.advance(by: .seconds(5))
        try await scene.clock.resumeAll(for: EventsLinkDefaults.probing.connectDeadline)
        try await waitFor { await scene.clock.hasWaiter(for: .seconds(10)) }

        scene.socket.failReceive(at: scene.now)
        try await releaseRetryDelay(scene, EventsLinkDefaults.firstDelay)
        try await waitFor { scene.socket.resumes == 2 }
        try await snapshot(scene)

        // The dead dial's arm, completing late, reaches nothing.
        scene.clock.advance(by: .seconds(20))
        try? await scene.clock.resumeAll(for: .seconds(10))
        await settle()
        #expect(scene.socket.goingAwayCancels == 0)
        #expect(scene.socket.resumes == 2)
        #expect(scene.events(.firstFrameDeadline).isEmpty)
    }

    @Test
    func aSnapshotBeforeTheFirstFrameDeadlineCancelsIt() async throws {
        let scene = try EventsScene(schedule: EventsLinkDefaults.probing)
        defer { scene.tearDown() }

        try await waitFor { await scene.clock.hasWaiter(for: EventsLinkDefaults.probing.connectDeadline) }
        scene.clock.advance(by: .seconds(5))
        try await scene.clock.resumeAll(for: EventsLinkDefaults.probing.connectDeadline)
        try await waitFor { await scene.clock.hasWaiter(for: .seconds(10)) }

        scene.clock.advance(by: .seconds(9))
        try await snapshot(scene)

        try await waitFor { await scene.clock.hasWaiter(for: .seconds(10)) == false }
        #expect(scene.socket.goingAwayCancels == 0)
        #expect(scene.events(.firstFrameDeadline).isEmpty)
    }
}
