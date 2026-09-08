import Foundation
@testable import Tavi
import Testing

// The 2 s handover check (#111 P2), through the real controller: an
// interface change asks the round in flight rather than replacing it, and
// the deadline it lands on is absolute and covers send and pong together.
// Every wait is resumed by the test; nothing here depends on elapsed time.
@MainActor
struct TerminalHandoverTests {
    // MARK: - The send half of the budget

    // The check is one deadline over both halves, so a challenge whose ping
    // never leaves the queue is a failed handover at 2 s — not at the 3 s
    // the queue would otherwise have had.
    @Test
    func aHandoverWhoseSendNeverCompletesCyclesAtTheHandoverDeadline() async throws {
        let transport = RecoveryTransport(hangsSends: true)
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let recovery = RecoveryLog(pathObserver: ScriptedPathObserver())
        let controller = HandoverFixture.controller(transport, clock, paths: paths, recovery: recovery)

        try await withCleanup(controller, transport) {
            try await HandoverFixture.beginRoundWithASuspendedSend(controller, transport, clock, paths)

            paths.emit(HandoverFixture.cellular)
            try await waitFor { await clock.hasWaiter(for: HandoverFixture.deadline) }
            #expect(await clock.hasWaiter(for: HandoverFixture.sendBound) == false)

            try await clock.resumeAll(for: HandoverFixture.deadline)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }

            let failure = try #require(recovery.ring.first { $0.kind == .handoverFailed })
            #expect(failure.reason == .handover(.sendStalled))
            // Verdict and cycle are one event class under one key, so the
            // counters cannot split a handover across two names.
            #expect(recovery.ring.last?.kind == .cycling)
            #expect(recovery.ring.last?.reason == .handover(.sendStalled))
            #expect(recovery.counters[.terminal]?.cycles[.handover(.sendStalled)] == 1)
            #expect(recovery.counters[.terminal]?.cycles[.terminal(.handoverSendStalled)] == nil)
        }
    }

    // The 2 s is measured from the path change, not from each half in turn:
    // a send that lands 0.1 s before the deadline leaves the host 0.1 s to
    // answer, never a fresh answer budget.
    @Test
    func aSendCompletingLateLeavesThePongOnlyWhatIsLeftOfTheDeadline() async throws {
        let transport = RecoveryTransport(hangsSends: true)
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let controller = HandoverFixture.controller(transport, clock, paths: paths)

        try await withCleanup(controller, transport) {
            try await HandoverFixture.beginRoundWithASuspendedSend(controller, transport, clock, paths)

            paths.emit(HandoverFixture.cellular)
            try await waitFor { await clock.hasWaiter(for: HandoverFixture.deadline) }

            clock.advance(by: .milliseconds(1_900))
            await transport.releaseSend()
            try await waitFor { await clock.hasWaiter(for: .milliseconds(100)) }
            #expect(await clock.timesScheduled(HandoverFixture.answerBound) == 0)
            #expect(controller.connectionState == .connected)

            try await clock.resumeAll(for: .milliseconds(100))
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
        }
    }

    // MARK: - Coalescing

    // A handover flaps: the interface list changes again and again while the
    // check is outstanding. The earliest deadline stands and there is still
    // exactly one round — a fresh round per event would ask a stalled queue
    // to carry three pings before any of them could be answered.
    @Test
    func flappingDuringAChallengeKeepsOneRoundAndItsEarliestDeadline() async throws {
        let transport = RecoveryTransport(hangsSends: true)
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let controller = HandoverFixture.controller(transport, clock, paths: paths)

        try await withCleanup(controller, transport) {
            try await HandoverFixture.beginRoundWithASuspendedSend(controller, transport, clock, paths)

            paths.emit(HandoverFixture.cellular)
            try await waitFor { await clock.timesScheduled(HandoverFixture.deadline) == 1 }

            clock.advance(by: .milliseconds(500))
            paths.emit(HandoverFixture.otherCellular)
            await settle()
            clock.advance(by: .milliseconds(500))
            paths.emit(HandoverFixture.cellular)
            await settle()

            #expect(await clock.timesScheduled(HandoverFixture.deadline) == 1)
            #expect(await transport.pingIdentifiers.count == 1)

            try await clock.resumeAll(for: HandoverFixture.deadline)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
            #expect(await transport.pingIdentifiers.count == 1)
        }
    }

    // A round already closer to its own deadline than the handover would put
    // it keeps that deadline: the check may only shorten a budget, never
    // lengthen one. Four seconds into a five-second answer, a handover ends
    // it at five, not at six.
    @Test
    func anOrdinaryRoundNearerItsDeadlineThanTheHandoverKeepsIt() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let recovery = RecoveryLog(pathObserver: ScriptedPathObserver())
        let controller = HandoverFixture.controller(transport, clock, paths: paths, recovery: recovery)

        try await withCleanup(controller, transport) {
            try await HandoverFixture.connect(controller, transport, paths)
            try await waitFor { await clock.hasWaiter(for: HandoverFixture.interval) }
            try await clock.resumeAll(for: HandoverFixture.interval)
            try await waitFor { await clock.hasWaiter(for: HandoverFixture.answerBound) }

            clock.advance(by: .seconds(4))
            paths.emit(HandoverFixture.cellular)
            try await waitFor { await clock.hasWaiter(for: .seconds(1)) }
            #expect(await clock.timesScheduled(HandoverFixture.deadline) == 0)
            #expect(await transport.pingIdentifiers.count == 1)

            try await clock.resumeAll(for: .seconds(1))
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
            let failure = try #require(recovery.ring.first { $0.kind == .handoverFailed })
            #expect(failure.reason == .handover(.pongMissing))
            #expect(recovery.counters[.terminal]?.cycles[.handover(.pongMissing)] == 1)
        }
    }

    // MARK: - The slow peer

    // The whole point of the shorter budget: a host that answers inside it
    // keeps the socket, and the log says the handover was checked.
    @Test
    func aPeerAnsweringInsideTheDeadlinePassesAndIsRecordedAsChecked() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let recovery = RecoveryLog(pathObserver: ScriptedPathObserver())
        let controller = HandoverFixture.controller(transport, clock, paths: paths, recovery: recovery)

        try await withCleanup(controller, transport) {
            try await HandoverFixture.connect(controller, transport, paths)
            paths.emit(HandoverFixture.cellular)
            // Both halves of the challenge are bounded by the same 2 s, so
            // the second registration is the ping being on the wire and the
            // answer's half of the deadline standing.
            try await waitFor { await clock.timesScheduled(HandoverFixture.deadline) == 2 }
            #expect(await clock.timesScheduled(HandoverFixture.answerBound) == 0)

            clock.advance(by: .milliseconds(1_900))
            let identifier = try #require(await transport.pingIdentifiers.last)
            await transport.emit(.message(.pong(identifier: identifier)))
            try await waitFor { await clock.hasWaiter(for: HandoverFixture.deadline) == false }

            #expect(controller.connectionState == .connected)
            let checked = try #require(recovery.ring.last)
            #expect(checked.kind == .handoverChecked)
            #expect(checked.generation == 1)
        }
    }

    // And a host 2.1 s away is a socket the handover broke.
    @Test
    func aPeerSlowerThanTheDeadlineCyclesTheConnection() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let recovery = RecoveryLog(pathObserver: ScriptedPathObserver())
        let controller = HandoverFixture.controller(transport, clock, paths: paths, recovery: recovery)

        try await withCleanup(controller, transport) {
            try await HandoverFixture.connect(controller, transport, paths)
            paths.emit(HandoverFixture.cellular)
            try await waitFor { await clock.timesScheduled(HandoverFixture.deadline) == 2 }

            let identifier = try #require(await transport.pingIdentifiers.last)
            clock.advance(by: .milliseconds(2_100))
            try await clock.resumeAll(for: HandoverFixture.deadline)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }

            let failure = try #require(recovery.ring.first { $0.kind == .handoverFailed })
            #expect(failure.reason == .handover(.pongMissing))

            // The answer turns up 2.1 s after the change, on a connection
            // that has already been written off. It is nobody's.
            await transport.emit(.message(.pong(identifier: identifier)))
            await settle()
            #expect(controller.connectionState == .reconnecting(attempt: 1))
            #expect(recovery.ring.contains { $0.kind == .handoverChecked } == false)
        }
    }

    // A pong and an expired deadline can reach the actor in either order.
    // The deadline decides: an answer that is already late does not undo a
    // miss just because it won that race.
    @Test
    func aPongPastTheDeadlineIsAMissEvenBeforeTheBoundHasFired() async throws {
        let transport = RecoveryTransport()
        let clock = ManualTerminalClock()
        let paths = ScriptedPathObserver()
        let recovery = RecoveryLog(pathObserver: ScriptedPathObserver())
        let controller = HandoverFixture.controller(transport, clock, paths: paths, recovery: recovery)

        try await withCleanup(controller, transport) {
            try await HandoverFixture.connect(controller, transport, paths)
            paths.emit(HandoverFixture.cellular)
            try await waitFor { await clock.timesScheduled(HandoverFixture.deadline) == 2 }
            let identifier = try #require(await transport.pingIdentifiers.last)

            // Past the deadline instant, with the bound's own task still
            // parked on the clock.
            clock.advance(by: .milliseconds(2_100))
            await transport.emit(.message(.pong(identifier: identifier)))
            await settle()
            #expect(recovery.ring.contains { $0.kind == .handoverChecked } == false)
            #expect(controller.connectionState == .connected)
            // The answer released nothing: the deadline is still standing.
            #expect(await clock.hasWaiter(for: HandoverFixture.deadline))

            try await clock.resumeAll(for: HandoverFixture.deadline)
            try await waitFor { controller.connectionState == .reconnecting(attempt: 1) }
            let failure = try #require(recovery.ring.first { $0.kind == .handoverFailed })
            #expect(failure.reason == .handover(.pongMissing))
        }
    }
}
