#if DEBUG
    import Foundation
    import SwiftUI

    // The chaos soak's only window into the phone's own counters (#111): a
    // real element in the accessibility tree, one pixel and invisible, whose
    // value is the whole `RecoveryLog` as one JSON line. It exists only in
    // DEBUG and only under a `TAVI_DEV_HOST` launch, and the encoding lives
    // here rather than on the model so the production type keeps no
    // serialisation API.
    //
    // One element per configured computer, so a screen showing several
    // publishes all of them and neither screen carries the gate itself.
    struct RecoveryDiagnosticsStrip: View {
        let directories: [AgentDirectory]

        var body: some View {
            if RecoveryDiagnosticsText.isEnabled {
                // A directory with no host id has nothing to be found by, and
                // two of them would collide as one row.
                ForEach(directories.filter { !$0.hostId.isEmpty }, id: \.hostId) { directory in
                    RecoveryDiagnosticsText(hostId: directory.hostId, log: directory.recovery)
                }
            }
        }
    }

    struct RecoveryDiagnosticsText: View {
        let hostId: String
        let log: RecoveryLog

        // The dev-host seed is what a scripted run is; a person's build
        // never carries this element.
        static var isEnabled: Bool {
            ProcessInfo.processInfo.environment["TAVI_DEV_HOST"] != nil
        }

        @State private var line = ""

        var body: some View {
            Text(line)
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityIdentifier("diagnostics.recovery.\(hostId)")
                .accessibilityValue(line)
                // Encoding fifty events belongs nowhere near `body`, which
                // SwiftUI re-runs on every redraw (#68); the soak samples
                // every two seconds, so once a second is ahead of it.
                .task {
                    while !Task.isCancelled {
                        line = log.diagnosticsLine(hostId: hostId)
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
        }
    }

    extension RecoveryLog {
        func diagnosticsLine(hostId: String) -> String {
            let payload = DiagnosticsPayload(
                host: hostId,
                terminal: .terminal(counters[.terminal] ?? Counters()),
                events: .events(counters[.events] ?? Counters()),
                ring: ring.map { DiagnosticsPayload.Event($0, since: startedAt) }
            )
            guard let data = try? JSONEncoder().encode(payload) else { return "" }
            return String(bytes: data, encoding: .utf8) ?? ""
        }
    }

    // Codable, not just Encodable: a test decodes the very type the encoder
    // writes, so the shape the soak reads cannot drift from the shape the
    // phone publishes without one of them failing to compile.
    struct DiagnosticsPayload: Codable {
        struct Counters: Codable {
            let dials: Int
            let readies: Int
            let resumeHits: Int
            let resumeMisses: Int
            let resumeMismatches: Int
            // The terminal's stream numbers; absent for the events link.
            let offsetGaps: Int?
            let offsetOverlaps: Int?
            let outputDiscarded: Int?
            let acceptedOffset: UInt64?
            let cycles: [String: Int]
            // The events link's verdicts about the computer; absent for the
            // terminal, which never says Offline.
            let offlineEntered: Int?
            let offlineCleared: Int?

            static func terminal(_ counters: RecoveryLog.Counters) -> Self {
                Self(
                    dials: counters.dials,
                    readies: counters.readies,
                    resumeHits: counters.resumeHits,
                    resumeMisses: counters.resumeMisses,
                    resumeMismatches: counters.resumeMismatches,
                    offsetGaps: counters.offsetGaps,
                    offsetOverlaps: counters.offsetOverlaps,
                    outputDiscarded: counters.outputDiscarded,
                    acceptedOffset: counters.acceptedOffset,
                    cycles: counters.cyclesByName,
                    offlineEntered: nil,
                    offlineCleared: nil
                )
            }

            static func events(_ counters: RecoveryLog.Counters) -> Self {
                Self(
                    dials: counters.dials,
                    readies: counters.readies,
                    resumeHits: counters.resumeHits,
                    resumeMisses: counters.resumeMisses,
                    resumeMismatches: counters.resumeMismatches,
                    offsetGaps: nil,
                    offsetOverlaps: nil,
                    outputDiscarded: nil,
                    acceptedOffset: nil,
                    cycles: counters.cyclesByName,
                    offlineEntered: counters.offlineEntered,
                    offlineCleared: counters.offlineCleared
                )
            }
        }

        struct Event: Codable {
            let at: Int
            let monotonic: Int
            let source: String
            let kind: String
            let reason: String
            let generation: Int
            let attempt: Int
            let elapsedMs: Int
            let resumed: Bool?
            let pathSatisfied: Bool?

            init(_ event: RecoveryEvent, since start: ContinuousClock.Instant) {
                at = Int(event.at.timeIntervalSince1970 * 1_000)
                monotonic = Int(start.milliseconds(to: event.monotonic))
                source = event.source.rawValue
                kind = event.kind.diagnosticsName
                reason = event.reason.diagnosticsName
                generation = event.generation
                attempt = event.attempt
                elapsedMs = event.elapsedMilliseconds
                resumed = event.resumed
                pathSatisfied = event.pathSatisfied
            }
        }

        let host: String
        let terminal: Counters
        let events: Counters
        let ring: [Event]
    }

    private extension RecoveryLog.Counters {
        var cyclesByName: [String: Int] {
            Dictionary(uniqueKeysWithValues: cycles.map { ($0.key.diagnosticsName, $0.value) })
        }
    }

    private extension RecoveryLog.Kind {
        var diagnosticsName: String {
            switch self {
            case .cycling: "cycling"
            case .ready: "ready"
            case .takenOver: "takenOver"
            case .streamEnded: "streamEnded"
            case .snapshotAfterDrop: "snapshotAfterDrop"
            case .offlineEntered: "offlineEntered"
            case .offlineCleared: "offlineCleared"
            case .revoked: "revoked"
            case .outputDiscarded: "outputDiscarded"
            case .offsetGap: "offsetGap"
            case .offsetOverlap: "offsetOverlap"
            case .handoverChecked: "handoverChecked"
            case .handoverFailed: "handoverFailed"
            case .firstFrameDeadline: "firstFrameDeadline"
            case let .probe(probe): "probe.\(probe.rawValue)"
            }
        }
    }

    private extension RecoveryLog.Reason {
        var diagnosticsName: String {
            switch self {
            case let .terminal(reason): "terminal:\(reason.rawValue)"
            case let .socket(tag, code): "socket:\(tag.rawValue):\(code)"
            case .none: "none"
            }
        }
    }
#endif
