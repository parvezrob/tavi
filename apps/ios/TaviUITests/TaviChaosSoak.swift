import XCTest

// The chaos soak (#111): twenty minutes against a host started with
// `TAVI_CHAOS=on`, half on a terminal and half on the home, with the runner
// firing every fault itself only once the phone's own counters show the
// socket has been healthy for thirty seconds — so a backoff reset is
// observed rather than presumed. Every duration reported is computed from the
// exported event timestamps in the phone's diagnostics element, never from
// when the two-second sampler happened to look; the sampler's own
// observations serve the UI assertions and carry their own ±2 s allowance.
//
// Owner-run, simulator only, and only with the owner off the phone: the Mac
// is the host. `TEST_RUNNER_TAVI_CHAOS=1` arms it,
// `TEST_RUNNER_TAVI_CHAOS_MINUTES` sets the length (default 20), and the live
// host env points at the chaos host. The assertions and the numbers are in
// `TaviChaosSoakReport.swift`.
@MainActor
final class TaviChaosSoak: XCTestCase {
    let sampleInterval: TimeInterval = 2
    let collector = RingCollector()
    var health: [HealthPoll] = []
    var samples: [Sample] = []
    var marks: [Mark] = []
    var fired: [FiredFault] = []
    // Pinned at smoke time, so every later read binds the one element this
    // computer publishes rather than whichever matched a prefix first.
    var diagnosticsIdentifier = ""
    // Reported in the numbers: a home phase with no room left is not a zero.
    var homePhaseSkipped = false
    // The faults a phase never got to fire, so a phase that started but ran
    // out of budget says which ones are missing from the numbers.
    var unfiredFaults: [String] = []
    // One identifier per health state for the soak's computer, pinned at
    // smoke time; the state is part of the identifier the home publishes.
    var healthIdentifiers: [(identifier: String, state: String)] = []
    // Read once at the checkpoint and reported from there.
    var tallyCounts: [String: Int]?
    // Reported, not asserted (the plan asks for the number).
    var slowReadySeconds: [Double] = []
    // Set once the run is armed; every step below asks the same host.
    var chaos: ChaosEnvironment?

    override func setUpWithError() throws {
        // A single missed budget must not cost the whole run its numbers: the
        // report has to land even when a phase records a failure.
        continueAfterFailure = true
    }

    // The fixture is a shell script typed into a real pty, and a syntax error
    // in it fails three minutes into a twenty-minute run looking like a phone
    // defect. `sh` itself checks it in the run's first seconds
    // (`installFixture` runs `sh -n` on the host before sourcing it); this
    // needs no host and guards the exact shape that broke — the lines joined
    // with "; ", which produced `&;`, `in;` and `;; ;`.
    func testFixtureScriptIsShapedLikeAShellScript() {
        let script = Self.fixtureScript(paneId: "pane-under-test")
        let lines = script.split(separator: "\n").map(String.init)
        for artefact in ["&;", "in;", "; ;", ";; ;", "do;"] {
            XCTAssertFalse(script.contains(artefact), "The fixture contains \(artefact), which sh does not accept.")
        }
        XCTAssertTrue(lines.contains("done"), "The fixture's reader loop is never closed.")
        XCTAssertTrue(lines.contains("esac"), "The fixture's case is never closed.")
        XCTAssertEqual(script.components(separatedBy: ";;").count - 1, 3, "The fixture's case must have exactly three arms.")
    }

    func testChaosSoak() async throws {
        let chaos = try chaosEnvironment()
        self.chaos = chaos
        let paneId = try await createDisposableShell(host: chaos.host, token: chaos.token)
        let app = launchIntoAgent(paneId, host: chaos.host, token: chaos.token)

        // Smoke, before anything is armed: the element exists and its value
        // decodes. Without it the run has no evidence and is not worth doing.
        let smoke = try smokeDiagnostics(app)
        collector.merge(smoke)

        let started = Date()
        let half = TimeInterval(chaos.minutes) * 60 / 2
        let ends = started.addingTimeInterval(TimeInterval(chaos.minutes) * 60)
        // A step that gives up mid-run is a finding, not a reason to lose the
        // twenty minutes of numbers behind it: the report always runs.
        do {
            try await terminalPhase(app, chaos: chaos, paneId: paneId, until: started.addingTimeInterval(half))
            // The terminal phase may have run long; the home phase gets what
            // is left of the budget rather than extending the run past it.
            let homeDeadline = min(ends, Date().addingTimeInterval(half))
            let needed = EventsFault.allCases.reduce(0) { $0 + $1.needsSeconds }
            if homeDeadline.timeIntervalSinceNow >= needed {
                try await homePhase(app, chaos: chaos, until: homeDeadline)
            } else {
                homePhaseSkipped = true
                unfiredFaults.append(contentsOf: EventsFault.allCases.map(\.name))
                XCTFail("terminal phase overran; home phase skipped")
            }
        } catch {
            XCTFail("The soak stopped early: \(error)")
        }
        try await report(chaos)
    }

    // MARK: - Terminal phase

    private func terminalPhase(_ app: XCUIApplication, chaos: ChaosEnvironment, paneId: String, until deadline: Date) async throws {
        XCTAssertTrue(waitForLiveTerminal(app, timeout: 60), "The terminal never came up against the chaos host.")
        try installFixture(app, paneId: paneId)

        var index = 0
        var cycle = CycleState()
        while Date() < deadline {
            try await tick(app, chaos: chaos)
            let live = liveSeconds("terminal")
            if cycle.readyAt != lastReadyAt("terminal") {
                cycle = CycleState(readyAt: lastReadyAt("terminal"))
            }
            // One MARK into every fault-free window, one a second before the fault that ends it.
            if let live, live >= 10, !cycle.markedHealthy {
                cycle.markedHealthy = true
                type(app, mark: nextMark(.healthy))
            }
            guard let live, live >= ChaosBudget.liveBeforeFault, cycle.markedHealthy, !cycle.firedFault else { continue }
            let fault = TerminalFault.allCases[index % TerminalFault.allCases.count]
            // An overrun stays one fault's worth: a fault is fired only when
            // its own recovery still fits inside the phase.
            guard deadline.timeIntervalSinceNow >= fault.needsSeconds else {
                unfiredFaults.append(fault.name)
                break
            }
            cycle.firedFault = true
            type(app, mark: nextMark(.beforeFault))
            index += 1
            try await fire(fault, app: app, chaos: chaos, paneId: paneId)
        }
        try await checkpoint(app, chaos: chaos, paneId: paneId)
    }

    // The fixture: a background stream so the screen is never quiet, and a
    // reader that counts each MARK exactly once into a file on this Mac. The
    // `case` pattern is a glob, so the exact syntax is checked with `expr`;
    // anything else is reported as JUNK rather than silently swallowed.
    static func fixtureScript(paneId: String) -> String {
        let tally = tallyPath(paneId)
        return [
            "stty -echo",
            "( i=0; while :; do i=$((i+1)); echo \"SOAK $i\"; sleep 0.2; done ) &",
            "SOAK_PID=$!",
            ": > \(tally)",
            "while IFS= read -r line; do",
            "case \"$line\" in",
            "MARK-[0-9]*)",
            "if expr \"$line\" : '^MARK-[0-9][0-9]*$' >/dev/null; then",
            "printf '%s\\n' \"$line\" >> \(tally); printf 'ACK %s\\n' \"$line\"",
            "else printf 'JUNK %s\\n' \"$line\"; fi",
            ";;",
            "STOP)",
            "kill $SOAK_PID 2>/dev/null; wait $SOAK_PID 2>/dev/null; printf 'END\\n'",
            ";;",
            "*) printf 'JUNK %s\\n' \"$line\" ;;",
            "esac",
            "done",
        ].joined(separator: "\n")
    }

    private func installFixture(_ app: XCUIApplication, paneId: String) throws {
        let surface = app.descendants(matching: .any)["terminal.surface"]
        surface.tap()
        // One bracketed paste, the way the composer sends text, so no line of
        // the fixture can execute on its own half-typed: a heredoc writes it
        // to a file, `sh -n` checks it, and only then is it sourced — a
        // syntax error is named by the shell that would have run it, in the
        // first seconds rather than at minute three.
        let path = Self.fixturePath(paneId)
        let install = ([
            "cat > \(path) <<'TAVI_FIXTURE'",
            Self.fixtureScript(paneId: paneId),
            "TAVI_FIXTURE",
            "sh -n \(path) && echo FIXTURE-OK || echo FIXTURE-BAD",
        ] as [String]).joined(separator: "\n")
        surface.typeText("\u{1B}[200~\(install)\u{1B}[201~\r")
        guard waitForTranscript(of: surface, timeout: 30, until: { $0.contains("FIXTURE-OK") }) else {
            XCTFail("sh -n rejected the soak fixture, or the host never answered.")
            throw ChaosSoakFailure.fixtureRejected
        }
        surface.typeText("\u{1B}[200~. \(path)\u{1B}[201~\r")
        guard waitForTranscript(of: surface, timeout: 30, until: { $0.contains("SOAK ") }) else {
            XCTFail("The fixture never started streaming.")
            throw ChaosSoakFailure.fixtureRejected
        }
        app.buttons["terminal.dismissKeyboard"].tap()
    }

    private func fire(_ fault: TerminalFault, app: XCUIApplication, chaos: ChaosEnvironment, paneId: String) async throws {
        switch fault {
        case .terminate:
            let at = try await request(chaos, "terminate", .init(kind: "terminate", socket: "terminal", paneId: paneId))
            try await waitForRecovery(app, chaos: chaos, after: at, detection: 5, recovery: 30)
        case .blackhole:
            let at = try await request(
                chaos,
                "blackhole",
                .init(kind: "blackhole", socket: "terminal", paneId: paneId, ms: ChaosBudget.terminalBlackholeMs)
            )
            try await waitForRecovery(app, chaos: chaos, after: at, detection: ChaosBudget.terminalBlackholeDetection + 5, recovery: 60)
        case .slowReady:
            let at = try await request(
                chaos,
                "terminate+slowReady",
                .init(kind: "terminate", socket: "terminal", paneId: paneId, thenSlowReadyMs: ChaosBudget.slowReadyMs)
            )
            try await waitForRecovery(app, chaos: chaos, after: at, detection: 5, recovery: 40)
        case .closeMidOutput1011, .closeMidOutput1001:
            let code = fault == .closeMidOutput1011 ? 1_011 : 1_001
            let at = try await request(
                chaos,
                "closeMidOutput\(code)",
                .init(kind: "closeMidOutput", socket: "terminal", paneId: paneId, code: code)
            )
            try await waitForRecovery(app, chaos: chaos, after: at, detection: 5, recovery: 30)
        case .takeover:
            try await runTakeover(app, chaos: chaos, paneId: paneId)
        }
    }

    // The takeover is the harness's own: a second real `tavi.v2` client from
    // this process, which the host must hand the attachment to.
    private func runTakeover(_ app: XCUIApplication, chaos: ChaosEnvironment, paneId: String) async throws {
        let dialsBefore = try await readDiagnostics(app).terminal.dials
        let client = try XCTUnwrap(TakeoverClient(host: chaos.host, token: chaos.token, paneId: paneId))
        client.start()
        let sentence = app.descendants(matching: .any)["terminal.status"]
        XCTAssertTrue(sentence.waitForExistence(timeout: 5), "The superseded sentence never appeared after the takeover.")

        // A superseded terminal does not reclaim: sixty seconds and one
        // background/foreground must not add a single dial.
        try await Task.sleep(for: .seconds(30))
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(2))
        app.activate()
        try await Task.sleep(for: .seconds(28))
        let after = try await readDiagnostics(app)
        collector.merge(after)
        XCTAssertEqual(after.terminal.dials, dialsBefore, "A superseded terminal dialled again on its own.")
        client.stop()
        try await reopenTerminal(app, paneId: paneId)
    }

    // The final checkpoint: stop the stream, let the host go quiet, then hold
    // the phone's accepted offset against the host's own next-write offset.
    private func checkpoint(_ app: XCUIApplication, chaos: ChaosEnvironment, paneId: String) async throws {
        let surface = app.descendants(matching: .any)["terminal.surface"]
        surface.tap()
        surface.typeText("STOP\r")
        XCTAssertTrue(waitForTranscript(of: surface, timeout: 30) { $0.contains("END") }, "The fixture never acknowledged STOP.")
        app.buttons["terminal.dismissKeyboard"].tap()
        try await Task.sleep(for: .seconds(3))

        let line = try await readDiagnostics(app)
        collector.merge(line)
        // One row per pane: the host keys its attachments by pane id and a
        // replacement supersedes the incumbent, so a second row would mean
        // the contract changed. A missing row costs this comparison and
        // nothing else — the integrity counters and the tally still speak.
        let rows = ((try? await chaosAttachments(chaos)) ?? []).filter { $0.paneId == paneId }
        if rows.count == 1, let attachment = rows.first {
            XCTAssertEqual(
                line.terminal.acceptedOffset,
                attachment.endOffset,
                "The phone and the host disagree about how many bytes this stream produced."
            )
        } else {
            XCTFail("The host reported \(rows.count) attachments for this pane; there is no offset to compare against.")
        }
        assertIntegrity(line)
        assertMarks(paneId: paneId)
    }

    // MARK: - Home phase

    private func homePhase(_ app: XCUIApplication, chaos: ChaosEnvironment, until deadline: Date) async throws {
        closeTerminal(app)
        var index = 0
        var cycle = CycleState()
        while Date() < deadline, index < EventsFault.allCases.count {
            try await tick(app, chaos: chaos)
            if cycle.readyAt != lastReadyAt("events") {
                cycle = CycleState(readyAt: lastReadyAt("events"))
            }
            guard let live = liveSeconds("events"), live >= ChaosBudget.liveBeforeFault, !cycle.firedFault else { continue }
            let fault = EventsFault.allCases[index]
            // As in the terminal phase: a fault is fired only when its own
            // recovery still fits, so an overrun costs one fault, not the rest.
            guard deadline.timeIntervalSinceNow >= fault.needsSeconds else { break }
            cycle.firedFault = true
            index += 1
            try await fire(fault, app: app, chaos: chaos)
        }
        unfiredFaults.append(contentsOf: EventsFault.allCases.dropFirst(index).map(\.name))
    }

    private func fire(_ fault: EventsFault, app: XCUIApplication, chaos: ChaosEnvironment) async throws {
        switch fault {
        case .terminate:
            let at = try await request(chaos, "terminate", .init(kind: "terminate", socket: "events"))
            try await waitForEventsRecovery(app, chaos: chaos, after: at, detection: 10)
        case .blackhole:
            let at = try await request(
                chaos,
                "blackhole",
                .init(kind: "blackhole", socket: "events", ms: ChaosBudget.eventsBlackholeMs)
            )
            try await waitForEventsRecovery(app, chaos: chaos, after: at, detection: ChaosBudget.eventsWatchdogCycle + 10)
        case .closeMidOutput1001:
            let at = try await request(chaos, "closeMidOutput1001", .init(kind: "closeMidOutput", socket: "events", code: 1_001))
            try await waitForEventsRecovery(app, chaos: chaos, after: at, detection: 10)
        case .hostPauseContrast:
            try await runContrast(app, chaos: chaos)
        }
    }

    // The deliberate contrast: with the host withholding every response,
    // Offline is the *correct* verdict, and proving the harness can see it is
    // what makes the false-Offline count above worth anything.
    private func runContrast(_ app: XCUIApplication, chaos: ChaosEnvironment) async throws {
        let window = Double(ChaosBudget.hostPauseMs) / 1_000
        let at = try await request(
            chaos,
            "hostPause",
            .init(kind: "blackhole", socket: "events", ms: ChaosBudget.hostPauseMs),
            scoredForRecovery: false
        )
        _ = try await request(
            chaos,
            "hostPause",
            .init(kind: "hostPause", socket: "events", ms: ChaosBudget.hostPauseMs),
            scoredForRecovery: false
        )

        var sawOffline = false
        let ends = Date().addingTimeInterval(window)
        while Date() < ends {
            try await tick(app, chaos: chaos)
            if samples.last?.health == "offline" { sawOffline = true }
            if collector.first("events", "offlineEntered", after: at) != nil, sawOffline { break }
        }
        XCTAssertNotNil(collector.first("events", "offlineEntered", after: at), "The host withheld every response and the phone never said Offline.")
        XCTAssertTrue(sawOffline, "The phone recorded Offline but the home never showed it.")

        // The window must be over before anything else asks the host a
        // question: an HTTP call into a withholding host hangs for its whole
        // timeout, and the report is what the run exists to produce.
        try await waitForHostToAnswer(chaos, within: window + 30)
        // Anchored on the fault, and on a snapshot rather than a cycle: when
        // the host starts answering again the next dial simply succeeds, and
        // no further cycle follows it.
        let back = try await waitForEvent(app, source: "events", kind: "ready", after: at, within: 120)
        XCTAssertTrue(back, "The events link never came back after the host stopped withholding.")
    }

    private func waitForHostToAnswer(_ chaos: ChaosEnvironment, within seconds: Double) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let poll = await poll(chaos)
            health.append(poll)
            if poll.answered { return }
            try await Task.sleep(for: .seconds(sampleInterval))
        }
        XCTFail("The chaos host never started answering again after its hostPause window.")
    }

    // MARK: - Waiting on the phone's own evidence

    // The UI says "live" before the phone has even noticed the fault, so the
    // wait starts with the phone's own record of the cycle.
    private func waitForRecovery(
        _ app: XCUIApplication,
        chaos: ChaosEnvironment,
        after at: Double,
        detection: Double,
        recovery: Double
    ) async throws {
        guard try await waitForEvent(app, source: "terminal", kind: "cycling", after: at, within: detection) else {
            XCTFail("The terminal never recorded a cycle within \(detection) s of the fault.")
            return
        }
        guard try await waitForEvent(app, source: "terminal", kind: "ready", after: at, within: recovery) else {
            XCTFail("The terminal never said ready again within \(recovery) s of the fault.")
            return
        }
        XCTAssertTrue(waitForLiveTerminal(app, timeout: 30), "The terminal recorded ready but the screen never went live.")
    }

    private func waitForEventsRecovery(_ app: XCUIApplication, chaos: ChaosEnvironment, after at: Double, detection: Double) async throws {
        guard try await waitForEvent(app, source: "events", kind: "cycling", after: at, within: detection) else {
            XCTFail("The events link never recorded a cycle within \(detection) s of the fault.")
            return
        }
        let back = try await waitForEvent(app, source: "events", kind: "ready", after: at, within: 90)
        XCTAssertTrue(back, "The events link never delivered a snapshot again after the fault.")
    }

    private func waitForEvent(
        _ app: XCUIApplication,
        source: String,
        kind: String,
        after at: Double,
        within seconds: Double
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try await tick(app, chaos: chaos)
            if collector.first(source, kind, after: at) != nil { return true }
        }
        return false
    }

    // MARK: - The tick

    // One turn of the sampler: the counters, the screen, and the runner's own
    // record of the host being up. Best effort; the budgets come from events.
    private func tick(_ app: XCUIApplication, chaos: ChaosEnvironment?) async throws {
        collector.merge(try await readDiagnostics(app))
        samples.append(sample(app))
        if let chaos { health.append(await poll(chaos)) }
        try await Task.sleep(for: .seconds(sampleInterval))
    }

    private func sample(_ app: XCUIApplication) -> Sample {
        let status = app.descendants(matching: .any)["terminal.status"]
        let keyboard = app.buttons["terminal.keyboard"]
        return Sample(
            at: milliseconds(),
            terminalIsLive: keyboard.exists && !status.exists,
            status: status.exists ? status.label : nil,
            surface: (app.descendants(matching: .any)["terminal.surface"].value as? String) ?? "",
            health: currentHealth(app)
        )
    }

    // MARK: - Marks

    private func nextMark(_ window: Mark.Window) -> Mark {
        let mark = Mark(number: marks.count + 1, window: window, at: milliseconds())
        marks.append(mark)
        return mark
    }

    // A lone return before every healthy MARK, so a fragment an abandoned
    // send left behind is delimited and lands as JUNK rather than glued to
    // the next marker.
    private func type(_ app: XCUIApplication, mark: Mark) {
        let surface = app.descendants(matching: .any)["terminal.surface"]
        surface.tap()
        if mark.window == .healthy { surface.typeText("\r") }
        surface.typeText("MARK-\(mark.number)\r")
        app.buttons["terminal.dismissKeyboard"].tap()
    }

    // MARK: - The chaos host

    @discardableResult
    private func request(
        _ chaos: ChaosEnvironment,
        _ name: String,
        _ fault: FaultRequest,
        scoredForRecovery: Bool = true
    ) async throws -> Double {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(chaos.host)/api/chaos/fault")))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(chaos.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(fault)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        // A 404 means the fault had nothing to hit, which is a failure of the
        // run rather than a tolerated outcome.
        guard status == 201, let ack = try? JSONDecoder().decode(FaultAck.self, from: data) else {
            XCTFail("The chaos host refused \(name): HTTP \(status) \(String(bytes: data.prefix(200), encoding: .utf8) ?? "")")
            throw ChaosSoakFailure.faultRefused
        }
        fired.append(
            FiredFault(
                name: name,
                id: ack.id,
                at: ack.at,
                socket: fault.socket,
                thenSlowReadyMs: fault.thenSlowReadyMs,
                scoredForRecovery: scoredForRecovery
            )
        )
        return ack.at
    }

    func chaosFaults(_ chaos: ChaosEnvironment) async throws -> [ChaosFaultRecord] {
        try await get(chaos, "/api/chaos/events", as: ChaosFaultList.self).events
    }

    func chaosAttachments(_ chaos: ChaosEnvironment) async throws -> [ChaosAttachment] {
        try await get(chaos, "/api/chaos/attachments", as: ChaosAttachmentList.self).attachments
    }

    private func get<T: Decodable>(_ chaos: ChaosEnvironment, _ path: String, as type: T.Type) async throws -> T {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(chaos.host)\(path)")))
        request.timeoutInterval = 10
        request.setValue("Bearer \(chaos.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            XCTFail("The chaos host did not answer \(path); was it started with TAVI_CHAOS=on?")
            throw ChaosSoakFailure.routeUnavailable
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // The runner's own record of the host being up. It is evidence about the
    // runner's path to the host, and is reported as exactly that.
    private func poll(_ chaos: ChaosEnvironment) async -> HealthPoll {
        guard let url = URL(string: "\(chaos.host)/api/health") else { return HealthPoll(at: milliseconds(), answered: false) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        let answered = (try? await URLSession.shared.data(for: request)).map { ($0.1 as? HTTPURLResponse)?.statusCode != nil } ?? false
        return HealthPoll(at: milliseconds(), answered: answered)
    }

    // MARK: - Screens

    private func closeTerminal(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        _ = app.descendants(matching: .any)["sessions.list"].waitForExistence(timeout: 10)
    }

    private func reopenTerminal(_ app: XCUIApplication, paneId: String) async throws {
        closeTerminal(app)
        let row = app.buttons["sessions.agent.\(paneId)"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The soak's pane is not on the home to reopen.")
        row.tap()
        XCTAssertTrue(waitForLiveTerminal(app, timeout: 60), "The terminal did not come back after the takeover.")
    }

    // MARK: - Plumbing

    private func chaosEnvironment() throws -> ChaosEnvironment {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TAVI_CHAOS"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_TAVI_CHAOS=1 to run the chaos soak (owner-run, simulator, against a TAVI_CHAOS=on host).")
        }
        let live = try LiveEnvironment.current()
        let minutes = environment["TAVI_CHAOS_MINUTES"].flatMap { Int($0) } ?? 20
        guard minutes > 0 else { throw XCTSkip("TEST_RUNNER_TAVI_CHAOS_MINUTES must be a positive number of minutes.") }
        return ChaosEnvironment(live: live, minutes: minutes)
    }

    // The runner and the chaos host share this Mac, so the fixture writes
    // its tally where the runner can read it from disk after END.
    static func tallyPath(_ paneId: String) -> String { "/tmp/tavi-soak-\(paneId).tally" }

    static func fixturePath(_ paneId: String) -> String { "/tmp/tavi-soak-\(paneId).sh" }

    // Below this the home phase cannot fire its four faults and wait them
    // out, so it is not started at all.
    static let healthStates = ["connecting", "live", "stale", "offline", "revoked"]

    func milliseconds() -> Double { Date().timeIntervalSince1970 * 1_000 }
}
