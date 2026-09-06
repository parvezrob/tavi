import Foundation
@testable import Tavi
import Testing

// What one computer's connection log is allowed to hold (#111): fifty
// events, counters that outlive them, one current stream offset, and a path
// stamp. Production retention is exactly this — a soak's full history is
// the test collector's.
@MainActor
struct RecoveryLogTests {
    private func log(_ paths: ScriptedPathObserver = ScriptedPathObserver()) -> RecoveryLog {
        RecoveryLog(pathObserver: paths)
    }

    // MARK: - The ring

    @Test func theFiftyFirstEventDropsTheOldest() {
        let recovery = log()
        for attempt in 1...51 {
            recovery.record(.cycling, source: .terminal, reason: .terminal(.transportFailed), attempt: attempt)
        }
        #expect(recovery.ring.count == RecoveryLog.ringCapacity)
        #expect(recovery.ring.first?.attempt == 2)
        #expect(recovery.ring.last?.attempt == 51)
    }

    @Test func eventsAreKeptInTheOrderTheyHappened() {
        let recovery = log()
        recovery.record(.ready, source: .terminal, resumed: true)
        recovery.record(.streamEnded, source: .events)
        recovery.record(.probe(.unreachable), source: .events)
        #expect(recovery.ring.map(\.kind) == [.ready, .streamEnded, .probe(.unreachable)])
    }

    // The ring is what a person reads; the counters are what a soak
    // compares, so they must survive the ring rolling over.
    @Test func countersKeepCountingPastTheRing() {
        let recovery = log()
        for _ in 0..<60 {
            recovery.record(.cycling, source: .events, reason: .socket(.closed, code: 1_011))
            recovery.tally(.dial, source: .events)
        }
        #expect(recovery.counters[.events]?.dials == 60)
        #expect(recovery.counters[.events]?.cycles[.socket(.closed, code: 1_011)] == 60)
        #expect(recovery.ring.count == RecoveryLog.ringCapacity)
    }

    @Test func eachSourceCountsOnlyItsOwn() {
        let recovery = log()
        recovery.record(.ready, source: .terminal)
        recovery.tally(.dial, source: .events)
        #expect(recovery.counters[.terminal]?.readies == 1)
        #expect(recovery.counters[.events]?.readies == 0)
        #expect(recovery.counters[.terminal]?.dials == 0)
    }

    // MARK: - The current stream

    @Test func theAcceptedOffsetIsReplacedOnAFreshAttach() {
        let recovery = log()
        recovery.noteAcceptedOffset(4_096)
        #expect(recovery.counters[.terminal]?.acceptedOffset == 4_096)
        recovery.noteAcceptedOffset(nil)
        #expect(recovery.counters[.terminal]?.acceptedOffset == nil)
        recovery.noteAcceptedOffset(0)
        #expect(recovery.counters[.terminal]?.acceptedOffset == 0)
    }

    // MARK: - The path stamp

    @Test func everyEventCarriesThePathTheWatchLastSaw() async throws {
        let paths = ScriptedPathObserver()
        let recovery = log(paths)
        paths.emit(NetworkPathSnapshot(isSatisfied: false, interfaceIdentity: "none"))
        try await waitFor { recovery.pathSatisfied == false }
        recovery.record(.cycling, source: .terminal, reason: .terminal(.networkPathLost))
        #expect(recovery.ring.last?.pathSatisfied == false)

        paths.emit(NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "en0"))
        try await waitFor { recovery.pathSatisfied == true }
        recovery.record(.ready, source: .terminal)
        #expect(recovery.ring.last?.pathSatisfied == true)
    }

    // The log is dropped with the computer it belongs to; the monitor it
    // started must go with it.
    @Test func stoppingTheLogEndsItsPathWatch() async throws {
        let paths = ScriptedPathObserver()
        let recovery = log(paths)
        paths.emit(NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "en0"))
        try await waitFor { recovery.pathSatisfied == true }

        recovery.stop()
        #expect(recovery.isWatching == false)
        #expect(recovery.pathSatisfied == nil)
        paths.emit(NetworkPathSnapshot(isSatisfied: false, interfaceIdentity: "none"))
        await settle()
        #expect(recovery.pathSatisfied == nil)
    }

    // MARK: - The diagnostics line

    #if DEBUG
        @Test func theDiagnosticsLineDecodesBackToWhatWasRecorded() throws {
            let recovery = log()
            recovery.tally(.dial, source: .terminal)
            recovery.noteAcceptedOffset(2_048)
            recovery.tally(.resumeMismatch, source: .terminal)
            recovery.record(
                .cycling,
                source: .terminal,
                reason: .terminal(.heartbeatPongMissing),
                generation: 4,
                attempt: 2,
                elapsedMilliseconds: 5_001,
                resumed: false
            )
            recovery.record(.cycling, source: .events, reason: .socket(.closed, code: 1_001))
            recovery.record(.probe(.rejected), source: .events)
            recovery.record(.offlineEntered, source: .events)
            recovery.record(.outputDiscarded, source: .terminal)

            let line = recovery.diagnosticsLine(hostId: "mac-1")
            #expect(!line.contains("\n"))
            let decoded = try JSONDecoder().decode(DiagnosticsPayload.self, from: Data(line.utf8))

            #expect(decoded.host == "mac-1")
            #expect(decoded.terminal.dials == 1)
            #expect(decoded.terminal.resumeMismatches == 1)
            #expect(decoded.terminal.acceptedOffset == 2_048)
            #expect(decoded.terminal.offsetGaps == 0)
            #expect(decoded.terminal.outputDiscarded == 1)
            #expect(decoded.terminal.cycles["terminal:heartbeat-pong-missing"] == 1)
            // The events block carries the Offline verdicts and no offsets.
            #expect(decoded.events.cycles["socket:closed:1001"] == 1)
            #expect(decoded.events.offlineEntered == 1)
            #expect(decoded.events.acceptedOffset == nil)
            #expect(decoded.events.offsetGaps == nil)

            let cycling = try #require(decoded.ring.first { $0.kind == "cycling" && $0.source == "terminal" })
            #expect(cycling.reason == "terminal:heartbeat-pong-missing")
            #expect(cycling.generation == 4)
            #expect(cycling.attempt == 2)
            #expect(cycling.elapsedMs == 5_001)
            #expect(cycling.resumed == false)
            #expect(cycling.at > 1_700_000_000_000)
            #expect(cycling.monotonic >= 0)
            #expect(decoded.ring.contains { $0.kind == "probe.rejected" })
        }
    #endif
}
