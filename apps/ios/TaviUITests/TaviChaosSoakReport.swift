import XCTest

// What the chaos soak concludes (#111): the budgets, the integrity checks,
// the false-Offline arithmetic, and the numbers the run exists to produce.
// Every duration here is computed from the timestamps the phone exported —
// fault `at` → `cycling` is detection, `cycling` → `ready` is recovery — and
// never from when the two-second sampler happened to look. The sampler's own
// observations are checked separately, with their ±2 s allowance.
extension TaviChaosSoak {
    func report(_ chaos: ChaosEnvironment) async throws {
        let records = (try? await chaosFaults(chaos)) ?? []
        var detection: [String: [Double]] = [:]
        var recovery: [String: [Double]] = [:]
        var attempts: [Int] = []

        for fault in fired {
            let source = fault.socket == "terminal" ? "terminal" : "events"
            guard let cycled = collector.first(source, "cycling", after: fault.at) else {
                XCTFail("\(fault.name) on the \(fault.socket) socket produced no cycle at all.")
                continue
            }
            detection[fault.name, default: []].append((Double(cycled.at) - fault.at) / 1_000)
            guard let back = collector.first(source, "ready", after: Double(cycled.at)) else {
                XCTFail("\(fault.name) on the \(fault.socket) socket never came back.")
                continue
            }
            attempts.append(back.attempt)
            recovery[fault.name, default: []].append(Double(back.at - cycled.at) / 1_000)
            guard fault.scoredForRecovery else { continue }
            assertBudget(fault, cycled: cycled, back: back, records: records)
        }

        assertSampler()
        let offline = assertFalseOffline()
        try attach(detection: detection, recovery: recovery, attempts: attempts, offline: offline)
    }

    // MARK: - Budgets

    private func assertBudget(_ fault: FiredFault, cycled: DiagnosticsEvent, back: DiagnosticsEvent, records: [ChaosFaultRecord]) {
        let attempt = max(1, back.attempt)
        let seconds = Double(back.at - cycled.at) / 1_000
        let detection = (Double(cycled.at) - fault.at) / 1_000
        switch (fault.name, fault.socket) {
        case ("terminate", "terminal"), ("closeMidOutput1011", "terminal"), ("closeMidOutput1001", "terminal"):
            let budget = attempt == 1
                ? ChaosBudget.terminalLiveAgainAtFirstAttempt
                : ChaosBudget.terminalDelay(attempt) + ChaosBudget.terminalReadyDeadline
            XCTAssertLessThanOrEqual(seconds, budget, "\(fault.name): the terminal took \(seconds) s to come back at attempt \(attempt).")
        case ("blackhole", "terminal"):
            XCTAssertLessThanOrEqual(
                detection,
                ChaosBudget.terminalBlackholeDetection,
                "The heartbeat took \(detection) s to notice a blackholed terminal."
            )
            let live = (Double(back.at) - fault.at) / 1_000
            XCTAssertLessThanOrEqual(live, ChaosBudget.terminalBlackholeLiveAgain, "The terminal was live again only \(live) s after the blackhole started.")
        case ("terminate+slowReady", "terminal"):
            // One cycle, the terminate's: a held `ready` must not induce a
            // second one at the 12 s deadline.
            let cycles = collector.all("terminal", "cycling", from: fault.at, to: Double(back.at)).count
            XCTAssertEqual(cycles, 1, "A held ready induced \(cycles) cycles; the deadline should have covered it.")
            // Reported, not asserted: the plan asks for upgrade + lookup + 6 s
            // against the 12 s deadline as a number to read.
            slowReadySeconds.append((Double(back.at) - fault.at) / 1_000)
            let consumed = records.first { $0.id == fault.id }?.consumedByAttachAt
            XCTAssertNotNil(consumed, "The host never reported an attach consuming this fault's slowReady.")
        case (_, "events"):
            if fault.name == "blackhole" {
                XCTAssertLessThanOrEqual(
                    detection,
                    ChaosBudget.eventsWatchdogCycle,
                    "The watchdog took \(detection) s to cycle a blackholed events socket."
                )
            }
            XCTAssertLessThanOrEqual(
                seconds,
                ChaosBudget.eventsDelay(attempt) + ChaosBudget.eventsLiveAgainAfterDial,
                "The events link took \(seconds) s to come back at attempt \(attempt)."
            )
        default:
            break
        }
    }

    // MARK: - Integrity

    // The stream the phone took and the stream the host wrote must be the
    // same bytes. `resumeMisses` are allowed only where this run deliberately
    // asked for a fresh attach: the initial one, and the reopen after the
    // takeover.
    func assertIntegrity(_ line: DiagnosticsLine) {
        XCTAssertEqual(line.terminal.offsetGaps, 0, "The output stream had a gap.")
        XCTAssertEqual(line.terminal.offsetOverlaps, 0, "The output stream overlapped.")
        XCTAssertEqual(line.terminal.outputDiscarded, 0, "Output was discarded before a surface took it.")
        XCTAssertEqual(line.terminal.resumeMismatches, 0, "A resumed ready answered at another offset.")
        XCTAssertEqual(
            line.terminal.resumeMisses - deliberateFreshAttaches,
            0,
            "The host restarted \(line.terminal.resumeMisses) attachments, of which only \(deliberateFreshAttaches) were asked for."
        )
    }

    // The first attach of the run, and one for every takeover this soak
    // performed and then explicitly reopened — the rotation reaches the
    // takeover every sixth fault, so there is rarely only one.
    private var deliberateFreshAttaches: Int {
        let initial = collector.events.contains { $0.source == "terminal" && $0.kind == "ready" } ? 1 : 0
        let reopened = collector.events
            .filter { $0.kind == "takenOver" }
            .filter { collector.first("terminal", "ready", after: Double($0.at)) != nil }
            .count
        return initial + reopened
    }

    // MARK: - The fixture's tally

    // The tally file, read from this Mac's disk: the runner and the chaos
    // host share the machine, and the screen only ever showed END.
    func assertMarks(paneId: String) {
        let path = TaviChaosSoak.tallyPath(paneId)
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("tally unreadable at \(path)")
            return
        }
        let counts = contents.split(separator: "\n").map(String.init).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        tallyCounts = counts
        for mark in marks {
            let name = "MARK-\(mark.number)"
            let count = counts[name] ?? 0
            XCTAssertLessThanOrEqual(count, 1, "\(name) executed \(count) times; input was replayed.")
            if mark.window == .healthy {
                XCTAssertEqual(count, 1, "\(name) was typed into a healthy terminal and did not execute exactly once.")
            }
        }
    }

    // The counts the checkpoint already read; a run that never reached the
    // checkpoint has none, and every MARK reads as never executed.
    private var markAcks: [String: [String: Int]] {
        let counts = tallyCounts ?? [:]
        var byWindow: [String: [String: Int]] = [:]
        for mark in marks {
            let count = counts["MARK-\(mark.number)"] ?? 0
            let bucket = count == 0 ? "never" : (count == 1 ? "once" : "twice")
            byWindow[mark.window.rawValue, default: ["once": 0, "never": 0, "twice": 0]][bucket, default: 0] += 1
        }
        return byWindow
    }

    // MARK: - What the sampler is for

    // Three things only a screenshot-level observation can say, each with the
    // sampler's own ±2 s allowance since it looks every two seconds.
    private func assertSampler() {
        assertOutputStaysFresh()
        assertRecoveriesAreVisible()
        assertHomeNeverLiesAboutOffline()
    }

    // `SOAK n` must keep advancing while the terminal is live: a screen that
    // stopped moving is a stream that stopped, whatever the counters say.
    private func assertOutputStaysFresh() {
        var lastNumber: Int?
        var lastChange = 0.0
        for sample in samples where sample.terminalIsLive {
            let number = Self.latestSoakNumber(in: sample.surface)
            guard let number else { continue }
            if number != lastNumber {
                lastNumber = number
                lastChange = sample.at
                continue
            }
            let stalled = (sample.at - lastChange) / 1_000
            if stalled > ChaosBudget.freshness + ChaosBudget.samplerAllowance {
                XCTFail("The SOAK stream stopped advancing for \(stalled) s while the terminal was live.")
                return
            }
        }
    }

    // Every recovery long enough for a person to see must have shown the
    // recovering label rather than a silently frozen screen.
    private func assertRecoveriesAreVisible() {
        let cycles = collector.events.filter { $0.source == "terminal" && $0.kind == "cycling" }
        for cycle in cycles {
            guard let back = collector.first("terminal", "ready", after: Double(cycle.at)),
                  Double(back.at - cycle.at) / 1_000 > 4 else { continue }
            let from = Double(cycle.at) - ChaosBudget.samplerAllowance * 1_000
            let to = Double(back.at) + ChaosBudget.samplerAllowance * 1_000
            // `terminal.keyboard` is also absent while a MARK is being typed,
            // so the recovering label itself is the signal.
            let seen = samples.contains { $0.at >= from && $0.at <= to && $0.status != nil }
            XCTAssertTrue(seen, "A recovery lasting more than four seconds was never visible on the terminal screen.")
        }
    }

    // The home's own health, beside the event log: the strip must never read
    // Offline in a window where the runner's polls all answered.
    private func assertHomeNeverLiesAboutOffline() {
        for sample in samples where sample.health == "offline" {
            let window = health.filter { abs($0.at - sample.at) <= ChaosBudget.healthWindow * 1_000 }
            guard !window.isEmpty, window.allSatisfy(\.answered) else { continue }
            // The contrast deliberately makes the host stop answering; a
            // window where it answered throughout is the defect.
            XCTFail("The home showed Offline while every one of the runner's health polls answered.")
            return
        }
    }

    // MARK: - False Offline

    // A false Offline is an `offlineEntered` inside a window where every one
    // of the runner's polls answered and the phone's path was satisfied. Two
    // kinds of window are incomplete measurements rather than zeros: one with
    // no health poll at all, and one where the phone recorded no path
    // evidence. Both are counted and reported, never quietly skipped.
    private func assertFalseOffline() -> OfflineTally {
        var incomplete = 0
        var disagreements = 0
        var failures = 0
        for event in collector.events where event.kind == "offlineEntered" {
            let window = health.filter { abs($0.at - Double(event.at)) <= ChaosBudget.healthWindow * 1_000 }
            if window.isEmpty {
                incomplete += 1
                continue
            }
            guard window.allSatisfy(\.answered) else { continue }
            guard let path = event.pathSatisfied else {
                incomplete += 1
                continue
            }
            guard path else { continue }
            // The phone said unreachable while the runner reached the host on
            // a satisfied path. That disagreement is the defect being hunted,
            // so it fails rather than being excluded.
            let probes = collector.events.filter {
                $0.kind == "probe.unreachable" && abs(Double($0.at) - Double(event.at)) <= ChaosBudget.healthWindow * 1_000
            }
            disagreements += probes.count
            failures += 1
            XCTFail("Offline while the host answered on a satisfied path (\(probes.count) unreachable phone probes in the window).")
        }
        if incomplete > 0 {
            print("chaos soak: \(incomplete) Offline verdicts had no health or path evidence — incomplete measurements, not zeros.")
        }
        return OfflineTally(falseOffline: failures, incomplete: incomplete, probeDisagreements: disagreements)
    }

    // MARK: - The numbers

    private func attach(
        detection: [String: [Double]],
        recovery: [String: [Double]],
        attempts: [Int],
        offline: OfflineTally
    ) throws {
        var table = "chaos soak — seconds per fault kind\n"
        table += "kind                  n  det.min  det.med  det.max  rec.min  rec.med  rec.max\n"
        var faults: [String: Any] = [:]
        for kind in Set(detection.keys).union(recovery.keys).sorted() {
            let detected = Distribution(detection[kind] ?? [])
            let recovered = Distribution(recovery[kind] ?? [])
            let cells = [detected.min, detected.median, detected.max, recovered.min, recovered.median, recovered.max]
                .map { String(format: "%8.2f", $0) }
            table += kind.padding(toLength: 21, withPad: " ", startingAt: 0)
                + String(format: " %2d ", detected.count) + cells.joined(separator: " ") + "\n"
            faults[kind] = ["detection": detected.asJSON, "recovery": recovered.asJSON]
        }
        print(table)

        let terminal = collector.events.filter { $0.source == "terminal" }
        let payload: [String: Any] = [
            "faults": faults,
            "attemptsAtEachCycle": attempts,
            // The dial itself, as the phone timed it: the elapsed time each
            // `ready` carries. The redial delay in front of it is already
            // under "recovery" above.
            "dialLatencyMs": [
                "terminal": Distribution(readyElapsed("terminal")).asJSON,
                "events": Distribution(readyElapsed("events")).asJSON,
            ],
            "slowReadyAfterFaultSeconds": Distribution(slowReadySeconds).asJSON,
            "homePhaseSkipped": homePhaseSkipped,
            "unfiredFaults": unfiredFaults,
            "resume": [
                "hits": terminal.filter { $0.kind == "ready" && $0.resumed == true }.count,
                "deliberateFreshAttaches": deliberateFreshAttaches,
            ],
            "cyclesByReason": Dictionary(grouping: collector.events.filter { $0.kind == "cycling" }, by: \.reason).mapValues(\.count),
            "offsets": [
                "gaps": collector.events.filter { $0.kind == "offsetGap" }.count,
                "overlaps": collector.events.filter { $0.kind == "offsetOverlap" }.count,
            ],
            "offline": [
                "false": offline.falseOffline,
                "incompleteMeasurements": offline.incomplete,
                "probeDisagreements": offline.probeDisagreements,
            ],
            "markAcks": markAcks,
            "events": collector.events.map {
                ["at": $0.at, "source": $0.source, "kind": $0.kind, "reason": $0.reason, "attempt": $0.attempt, "elapsedMs": $0.elapsedMs]
            },
            "healthPolls": health.map { ["at": $0.at, "answered": $0.answered] },
            "samples": samples.count,
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        attachment.name = "chaos-soak-numbers.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func readyElapsed(_ source: String) -> [Double] {
        collector.events.filter { $0.source == source && $0.kind == "ready" }.map { Double($0.elapsedMs) }
    }

    // The fixture prints `SOAK <n>` five times a second; the highest number
    // on screen is how far the stream has got.
    static func latestSoakNumber(in surface: String) -> Int? {
        surface.split(separator: "\n")
            .compactMap { line -> Int? in
                guard line.hasPrefix("SOAK ") else { return nil }
                return Int(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
            }
            .max()
    }
}

// What the false-Offline pass concluded, including the windows it could not
// measure: an unmeasured window is never reported as a zero.
struct OfflineTally {
    let falseOffline: Int
    let incomplete: Int
    let probeDisagreements: Int
}
