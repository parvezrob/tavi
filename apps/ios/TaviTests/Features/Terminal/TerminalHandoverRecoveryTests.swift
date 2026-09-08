import Foundation
@testable import Tavi
import Testing

// What a handover check must survive: the socket it is questioning going
// away underneath it, a suspended send from a connection that is already
// gone, and a link that came back rather than merely moved (#111 P2).
@MainActor
struct TerminalHandoverRecoveryTests {
    // MARK: - A close delivered mid-challenge

    // The ordering that wedges a state machine: the socket goes away while
    // the challenge is outstanding. One retry, the stream resumed at the
    // byte the phone had, and the round the dead socket owned takes nothing
    // with it — neither its late pong nor its deadline may touch the
    // replacement's heartbeat.
    @Test
    func aCloseMidChallengeRetriesOnceAndLeavesTheReplacementIntact() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let recovery = RecoveryLog(pathObserver: ScriptedPathObserver())
        let controller = HandoverFixture.controller(transport, clock, paths: paths, recovery: recovery)

        try await withCleanup(controller, transport) {
            try await HandoverFixture.connect(controller, transport, paths)
            await transport.emit(.message(.outputChunk(offset: 0, data: Data("hello".utf8))))
            await transport.emit(.message(.outputChunk(offset: 5, data: Data(" world".utf8))))
            try await waitFor { recovery.counters[.terminal]?.acceptedOffset == 11 }

            paths.emit(HandoverFixture.cellular)
            try await waitFor { await clock.timesScheduled(HandoverFixture.deadline) == 2 }
            let stale = try #require(await transport.pingIdentifiers.last)

            await transport.emit(.disconnected)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
            // The dead socket's deadline went with it.
            #expect(await clock.hasWaiter(for: HandoverFixture.deadline) == false)

            try await waitFor { await clock.hasWaiter(within: TerminalTestDefaults.retryDelay) }
            try await clock.resumeAll(within: TerminalTestDefaults.retryDelay)
            try await waitUntilListening(transport, after: 1)
            await transport.emit(.message(.ready(stream: "epoch-a", offset: 11, resumed: true)))
            try await waitFor { controller.connectionState == .connected }

            #expect(await transport.connectCount == 2)
            #expect(await transport.connectResumes.last ?? nil == TerminalResumePoint(stream: "epoch-a", offset: 11))

            // The old challenge's answer arrives on the new connection and
            // is nobody's: it may not be read as a passed handover.
            await transport.emit(.message(.pong(identifier: stale)))
            await settle()
            #expect(controller.connectionState == .connected)
            #expect(recovery.ring.contains { $0.kind == .handoverChecked } == false)

            // The replacement's own heartbeat is whole: its interval is
            // waiting, and it opens an ordinary round when that elapses.
            try await waitFor { await clock.hasWaiter(for: HandoverFixture.interval) }
            try await clock.resumeAll(for: HandoverFixture.interval)
            try await waitFor { await transport.pingIdentifiers.count == 2 }
            try await waitFor { await clock.hasWaiter(for: HandoverFixture.answerBound) }
        }
    }

    // MARK: - A stale beat

    // A hung send released long after its connection was replaced: the beat
    // it belonged to resumes on the live round's actor and must touch none
    // of it. Cancelling the *property* there took the replacement's send
    // bound with it, and a replacement whose own send then stalled had
    // nothing left to notice it — Connected, accepting keystrokes, forever.
    @Test
    func aSendReleasedAfterItsConnectionWasReplacedTouchesNoLiveBound() async throws {
        let transport = RecoveryTransport(hangsSends: true)
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let controller = HandoverFixture.controller(transport, clock, paths: paths)

        try await withCleanup(controller, transport) {
            try await HandoverFixture.beginRoundWithASuspendedSend(controller, transport, clock, paths)

            // That whole connection goes away and is dialled again; the
            // first round's send is still suspended in the old transport.
            await transport.emit(.disconnected)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
            try await waitFor { await clock.hasWaiter(within: TerminalTestDefaults.retryDelay) }
            try await clock.resumeAll(within: TerminalTestDefaults.retryDelay)
            try await waitUntilListening(transport, after: 1)
            await transport.emit(.message(.ready(stream: "epoch-a", offset: 0, resumed: true)))
            try await waitFor { controller.connectionState == .connected }

            // The replacement opens a round of its own, and its send hangs too.
            try await waitFor { await clock.hasWaiter(for: HandoverFixture.interval) }
            try await clock.resumeAll(for: HandoverFixture.interval)
            try await waitFor { await clock.timesScheduled(HandoverFixture.sendBound) == 2 }

            // Now the first connection's send finally returns.
            await transport.releaseSend()
            await settle()

            // The replacement's bound is untouched, and still fires on time.
            #expect(await clock.hasWaiter(for: HandoverFixture.sendBound))
            #expect(controller.connectionState == .connected)
            try await clock.resumeAll(for: HandoverFixture.sendBound)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 2) }
        }
    }

    // MARK: - A network that came back

    // `restored` on a socket that is still Connected is the same question as
    // `changed` — the link moved while this connection was up — so it gets
    // the same 2 s check rather than a tear-down.
    @Test
    func aRestoredPathOnAConnectedSocketIsAlsoAHandoverCheck() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let recovery = RecoveryLog(pathObserver: ScriptedPathObserver())
        let controller = HandoverFixture.controller(transport, clock, paths: paths, recovery: recovery)

        try await withCleanup(controller, transport) {
            try await HandoverFixture.connect(controller, transport, paths)

            // The link goes away and the terminal cycles; the dial that
            // replaces it succeeds while the monitor still says nothing.
            paths.emit(NetworkPathSnapshot(isSatisfied: false, interfaceIdentity: "none"))
            try await waitFor { await clock.hasWaiter(within: TerminalTestDefaults.retryDelay) }
            try await clock.resumeAll(within: TerminalTestDefaults.retryDelay)
            try await waitUntilListening(transport, after: 1)
            await transport.emit(.message(.ready(stream: "epoch-a", offset: 0, resumed: true)))
            try await waitFor { controller.connectionState == .connected }

            paths.emit(HandoverFixture.wifi)
            try await waitFor { await clock.timesScheduled(HandoverFixture.deadline) == 2 }
            #expect(await transport.connectCount == 2)

            let identifier = try #require(await transport.pingIdentifiers.last)
            await transport.emit(.message(.pong(identifier: identifier)))
            try await waitFor { recovery.ring.contains { $0.kind == .handoverChecked } }
            #expect(controller.connectionState == .connected)
        }
    }
}
