import Foundation
import Observation

// What one paired computer's connections have recovered from since Tavi
// opened (#111): the last 50 events, and counters that keep counting past
// them. Deliberately closed: every field is an enum case, a number or a
// flag, so nothing a person types, a host names or a socket says can reach
// this record. Production retention is exactly this — the complete history
// of a soak belongs to the test collector.
struct RecoveryEvent {
    let at: Date
    let monotonic: ContinuousClock.Instant
    let source: RecoveryLog.Source
    let kind: RecoveryLog.Kind
    let reason: RecoveryLog.Reason
    let generation: Int
    let attempt: Int
    let elapsedMilliseconds: Int
    let resumed: Bool?
    let pathSatisfied: Bool?
}

@MainActor
@Observable
final class RecoveryLog {
    enum Source: String {
        case terminal
        case events
    }

    // What the phone asked the computer and what it answered.
    enum Probe: String {
        case reachable
        case unreachable
        case rejected
    }

    enum Kind: Equatable {
        case cycling
        case ready
        case takenOver
        case streamEnded
        case snapshotAfterDrop
        case offlineEntered
        case offlineCleared
        case revoked
        case outputDiscarded
        case offsetGap
        case offsetOverlap
        case handoverChecked
        case handoverFailed
        // Nobody records this before P2's first-frame deadline exists; the
        // case is here so the schema a soak decodes is already final.
        case firstFrameDeadline
        case probe(Probe)
    }

    enum Reason: Hashable {
        case terminal(TerminalRecoveryReason)
        case socket(SocketFailure.Tag, code: Int)
        // The events watchdog cycled a socket that had gone quiet; the cancel
        // it performs would otherwise read as an ordinary cancelled socket.
        case watchdog
        case none
    }

    // The facts a connection counts without a ring entry: a dial has no
    // outcome yet, and a resume answer is a number the `ready` beside it
    // already narrates.
    enum Tally {
        case dial
        case resumeHit
        case resumeMiss
        case resumeMismatch
    }

    struct Counters {
        var dials = 0
        var readies = 0
        var resumeHits = 0
        var resumeMisses = 0
        var resumeMismatches = 0
        var offsetGaps = 0
        var offsetOverlaps = 0
        var outputDiscarded = 0
        var offlineEntered = 0
        var offlineCleared = 0
        // The current terminal stream's only; a fresh attach replaces it.
        var acceptedOffset: UInt64?
        var cycles: [Reason: Int] = [:]
    }

    static let ringCapacity = 50

    private(set) var ring: [RecoveryEvent] = []
    private(set) var counters: [Source: Counters] = [
        .terminal: Counters(),
        .events: Counters(),
    ]

    let startedAt: ContinuousClock.Instant

    private let timing: ConnectionTiming
    // Diagnostic only: the stamp on every event, so a soak can tell a
    // computer that stopped answering from a phone that lost its network.
    // Nothing in production hangs on it until P2.
    private let pathWatch: NetworkPathWatch

    init(timing: ConnectionTiming = .live, pathObserver: any NetworkPathObserving = NetworkPathObserver()) {
        self.timing = timing
        pathWatch = NetworkPathWatch(observer: pathObserver)
        startedAt = timing.now()
        pathWatch.start { _ in }
    }

    // Read by `record` alone; exposed so a test can wait for the watch to
    // have seen its scripted path before it asks for a stamp.
    var pathSatisfied: Bool? { pathWatch.current?.isSatisfied }

    // False once the computer this log belongs to has been dropped: nothing
    // may outlive it, least of all a path monitor (#111).
    private(set) var isWatching = true

    func stop() {
        pathWatch.stop()
        isWatching = false
    }

    // The one door for a recovery event: the ring, the counter its kind
    // moves, and the three stamps only this type can make.
    func record(
        _ kind: Kind,
        source: Source,
        reason: Reason = .none,
        generation: Int = 0,
        attempt: Int = 0,
        elapsedMilliseconds: Int = 0,
        resumed: Bool? = nil
    ) {
        ring.append(
            RecoveryEvent(
                at: Date(),
                monotonic: timing.now(),
                source: source,
                kind: kind,
                reason: reason,
                generation: generation,
                attempt: attempt,
                elapsedMilliseconds: elapsedMilliseconds,
                resumed: resumed,
                pathSatisfied: pathSatisfied
            )
        )
        if ring.count > Self.ringCapacity { ring.removeFirst(ring.count - Self.ringCapacity) }
        counters[source, default: Counters()].apply(kind, reason: reason)
    }

    // Counted, not narrated: these say nothing a ring entry would not repeat.
    func tally(_ tally: Tally, source: Source) {
        counters[source, default: Counters()].apply(tally)
    }

    // Where the current terminal stream has been taken to, replaced on every
    // fresh attach. State rather than a tally: it moves with every chunk, so
    // fifty ring entries would say nothing this number does not.
    func noteAcceptedOffset(_ offset: UInt64?) {
        counters[.terminal, default: Counters()].acceptedOffset = offset
    }
}

private extension RecoveryLog.Counters {
    mutating func apply(_ kind: RecoveryLog.Kind, reason: RecoveryLog.Reason) {
        switch kind {
        case .cycling: cycles[reason, default: 0] += 1
        case .ready: readies += 1
        case .offsetGap: offsetGaps += 1
        case .offsetOverlap: offsetOverlaps += 1
        case .outputDiscarded: outputDiscarded += 1
        case .offlineEntered: offlineEntered += 1
        case .offlineCleared: offlineCleared += 1
        case .takenOver, .streamEnded, .snapshotAfterDrop, .revoked,
             .handoverChecked, .handoverFailed, .firstFrameDeadline, .probe:
            break
        }
    }

    mutating func apply(_ tally: RecoveryLog.Tally) {
        switch tally {
        case .dial: dials += 1
        case .resumeHit: resumeHits += 1
        case .resumeMiss: resumeMisses += 1
        case .resumeMismatch: resumeMismatches += 1
        }
    }
}
