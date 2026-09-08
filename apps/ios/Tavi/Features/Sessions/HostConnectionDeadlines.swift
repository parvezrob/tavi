import Foundation
import os

// How often the events watchdog looks at its socket, and the two idle marks
// it acts on (#86, #107). Tests cross the same marks on a manual clock.
struct HostWatchdogPolicy: Sendable, Equatable {
    let pollInterval: Duration
    let pingAfterIdle: Duration
    let cycleAfterIdle: Duration

    // Effectively 20–25 s and 35–40 s, since the loop only looks every 5 s.
    // Safe to shorten from 30/45 because a host from 0.1.18 pings every 15 s
    // and a 0.1.17 host auto-pongs this link's own ping: a live socket is
    // never idle for 20 s, so what these marks catch is a dead one (#111).
    static let live = HostWatchdogPolicy(
        pollInterval: .seconds(5),
        pingAfterIdle: .seconds(20),
        cycleAfterIdle: .seconds(35)
    )
}

// One dial of the events stream, and every clock that can end it: the connect
// deadline, the watchdog, and what each of them tells the log. Carved out of
// `HostConnection` unchanged (#111 P2): the link owns its published state and
// its schedule, this owns the dial and the deadlines that cut it.
extension HostConnection {
    static let stableStreamInterval: Duration = .seconds(30)
    // From dial start, covering TCP, TLS, the upgrade and the wait for the
    // first agents frame.
    static let firstFrameDeadline: Duration = .seconds(15)

    func streamOnce(handshake: URLRequest) async {
        // This dial's place in the link's history; everything below judges
        // the socket it opens.
        epoch += 1
        let dial = epoch
        // This dial's own numbers, so every record it makes is about itself.
        let attempt = reconnectAttempt
        let dialledAt = timing.now()
        recovery?.tally(.dial, source: .events)
        let socket = makeSocket(handshake)
        self.socket = socket
        // A pong is how a handover challenge finds its own answer; the
        // payload is this link's own bytes and goes nowhere else (#111).
        socket.onPong { [weak self] payload in
            Task { @MainActor in self?.pongArrived(payload, dial: dial) }
        }
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            if self.socket === socket { self.socket = nil }
        }

        armConnectDeadline(dial, attempt: attempt, since: dialledAt)
        defer { cancelConnectDeadline(dial) }

        let watchdog = startWatchdog(for: socket, dial: dial, attempt: attempt, since: dialledAt)
        defer {
            watchdog.cancel()
            // Only this dial's challenges: the `self.socket` defer above runs
            // after this one, so the identity check still holds here.
            if self.socket === socket {
                cancelWatchdogPing()
                cancelHandover()
            }
        }

        var measured = false
        defer {
            // A dial that never produced a frame counts against the computer;
            // one that did resets the count. A cancelled dial still runs this,
            // by which time another computer may be in place.
            if dial == epoch {
                if measured { consecutiveFailedDials = 0 } else { consecutiveFailedDials += 1 }
                // The backoff forgets a stream that was alive across the
                // stable interval — frames delivered, not time passed
                // (#111). `lastFrameAt` is stamped by delivered frames
                // alone, so the error that ended this dial cannot pass for
                // life, and a socket that got one snapshot and then nothing
                // stays on the slow end of the schedule.
                if let since = streamConnectedAt, since.duration(to: socket.lastFrameAt) >= Self.stableStreamInterval {
                    reconnectAttempt = 0
                }
                streamConnectedAt = nil
            }
        }
        do {
            while !Task.isCancelled {
                let frame = try await socket.receive()
                guard dial == epoch else { return }
                guard case let .string(text) = frame else { continue }
                try apply(text, dial: dial, attempt: attempt, measured: &measured, dialledAt: dialledAt)
            }
        } catch {
            guard !Task.isCancelled, dial == epoch else { return }
            // Before the `defer` closes the socket: the cause is this stream's (#111).
            noteStreamEnded(error, dial: dial, attempt: attempt, since: dialledAt)
        }
    }

    // The end of a dial: what happened, then the last known agents kept on
    // screen explicitly stale, then the question of whether the computer
    // answers at all.
    func noteStreamEnded(_ error: Error, dial: Int, attempt: Int, since: ContinuousClock.Instant) {
        let failure = SocketFailure(error)
        Self.logger.info("events stream ended: reason=\(failure.tag.rawValue, privacy: .public) code=\(failure.code) priorFailedDials=\(self.consecutiveFailedDials)")
        recordStreamEnd(failure, dial: dial, attempt: attempt, since: since)
        markStale()
        verifyReachability(dial)
    }

    func cancelProbes() {
        reachability.cancel()
        connectDeadlineTask?.cancel()
        connectDeadlineTask = nil
        firstFrameLatencyTask?.cancel()
        firstFrameLatencyTask = nil
        reachabilityTask?.cancel()
        reachabilityTask = nil
    }

    // A snapshot is worth recording only when it ended a drop. Both of these
    // are out of line because `streamOnce` is at its length and complexity
    // bounds, not because either is worth a name of its own.
    func recordSnapshot(afterDrop: Bool, dial: Int, attempt: Int) {
        guard afterDrop else { return }
        recovery?.record(.snapshotAfterDrop, source: .events, generation: dial, attempt: attempt)
    }

    // The first frame of a dial is what proves the stream.
    func recordFirstFrame(dial: Int, attempt: Int, since: ContinuousClock.Instant) {
        let elapsed = Int(since.milliseconds(to: timing.now()))
        recovery?.record(.ready, source: .events, generation: dial, attempt: attempt, elapsedMilliseconds: elapsed)
    }

    // The cause belongs to whatever cut the socket, not to the cancel it
    // performs: the receive loop sees only a cancelled socket, a beat later
    // (#111). Recording before the cancel is what keeps the two in order.
    func cycleSocket(
        _ socket: any HostEventsSocketing,
        reason: RecoveryLog.Reason,
        dial: Int,
        attempt: Int,
        since: ContinuousClock.Instant
    ) {
        cycledDial = dial
        let lasted = Int(since.milliseconds(to: timing.now()))
        recovery?.record(.cycling, source: .events, reason: reason, generation: dial, attempt: attempt, elapsedMilliseconds: lasted)
        socket.cancel(with: .goingAway, reason: nil)
    }

    // A stream end is both what happened and why the link cycles — unless the
    // watchdog already said why, in which case this is only what.
    func recordStreamEnd(_ failure: SocketFailure, dial: Int, attempt: Int, since: ContinuousClock.Instant) {
        let cause = RecoveryLog.Reason.socket(failure.tag, code: failure.code)
        let lasted = Int(since.milliseconds(to: timing.now()))
        recovery?.record(.streamEnded, source: .events, reason: cause, generation: dial, attempt: attempt, elapsedMilliseconds: lasted)
        guard cycledDial != dial else { return }
        recovery?.record(.cycling, source: .events, reason: cause, generation: dial, attempt: attempt, elapsedMilliseconds: lasted)
    }

    // Bounded "Connecting…": if nothing has arrived by the deadline, ask the
    // host directly; no answer is Offline, said now, while the attempt keeps
    // going in case it is merely slow. The first frame cancels this.
    func armConnectDeadline(_ dial: Int, attempt: Int, since: ContinuousClock.Instant) {
        let deadline = reconnectPolicy.connectDeadline
        connectDeadlineTask?.cancel()
        connectDeadlineTask = Task { [weak self, timing] in
            try? await timing.sleep(deadline)
            guard !Task.isCancelled, let self else { return }
            // The question runs beside the rest of the budget, never in
            // front of it: two 5 s questions waited out first would push the
            // absolute first-frame deadline past 15 s. Structured, so
            // cancelling this task cancels both halves.
            async let asked: Void = self.probeAfterConnectDeadline(dial)
            await self.cutAtFirstFrameDeadline(dial: dial, attempt: attempt, since: since)
            await asked
        }
    }

    // Earned, not guessed (#86): the first dial that fails is "Connecting…"
    // or "Reconnecting"; Offline waits for the next.
    private func probeAfterConnectDeadline(_ dial: Int) async {
        let probe = await reachability.askTwice(reachabilityGeneration)
        guard !Task.isCancelled, dial == epoch else { return }
        if probe == .unreachable, consecutiveFailedDials >= 1 { setOffline(true, dial: dial) }
    }

    // The same task's second, later arm. A dial gets 15 s from its start to
    // deliver a first agents frame, the upgrade included: a host that
    // withholds the upgrade answer hangs the dial exactly as one that
    // connects and then says nothing does, and both used to wait for the
    // watchdog (#111, the 2026-09-08 hostPause finding — 45 s per dial, so
    // one frameless dial in a 120 s outage and Offline never earned).
    // Control frames do not extend it; the ordinary schedule redials.
    private func cutAtFirstFrameDeadline(dial: Int, attempt: Int, since: ContinuousClock.Instant) async {
        let spent = since.duration(to: timing.now())
        if spent < Self.firstFrameDeadline {
            try? await timing.sleep(Self.firstFrameDeadline - spent)
        }
        guard !Task.isCancelled, dial == epoch, let socket else { return }
        let waited = Int(since.milliseconds(to: timing.now()))
        recovery?.record(
            .firstFrameDeadline,
            source: .events,
            reason: .firstFrameDeadline,
            generation: dial,
            attempt: attempt,
            elapsedMilliseconds: waited
        )
        cycleSocket(socket, reason: .firstFrameDeadline, dial: dial, attempt: attempt, since: since)
    }

    // Only this dial's: a stream unwinding late must not cancel the
    // replacement's.
    func cancelConnectDeadline(_ dial: Int) {
        guard dial == epoch else { return }
        connectDeadlineTask?.cancel()
        connectDeadlineTask = nil
    }

    // Snapshots arrive on change only, so a dead socket looks exactly like a
    // quiet evening: ping after `pingAfterIdle`, cycle at `cycleAfterIdle`
    // (#86). The ping is never awaited here: awaiting it inline let a
    // suspended send keep the loop from ever reaching the cycle check (#107).
    func startWatchdog(
        for socket: any HostEventsSocketing,
        dial: Int,
        attempt: Int,
        since: ContinuousClock.Instant
    ) -> Task<Void, Never> {
        let policy = watchdogPolicy
        return Task { [weak self, weak socket, timing] in
            var challenged = false
            while !Task.isCancelled {
                try? await timing.sleep(policy.pollInterval)
                guard !Task.isCancelled, let self, let socket else { return }
                let idle = socket.lastActivity.duration(to: timing.now())
                if idle >= policy.cycleAfterIdle {
                    cancelWatchdogPing()
                    cycleSocket(socket, reason: .watchdog, dial: dial, attempt: attempt, since: since)
                    return
                }
                guard idle >= policy.pingAfterIdle else {
                    challenged = false
                    continue
                }
                guard !challenged else { continue }
                challenged = true
                challengeQuietSocket(socket)
            }
        }
    }

    // A fresh nonce per challenge, so a pong belongs to exactly one round and
    // a late one is told apart by its bytes (the events protocol allows 16;
    // eight is a nonce). Never logged (#111).
    static func challengePayload() -> Data {
        withUnsafeBytes(of: UInt64.random(in: .min ... .max)) { Data($0) }
    }

    // One challenge in flight per link until the send actually finishes: a
    // send that ignores cancellation must not be multiplied by the next
    // quiet period. Cancelling the socket releases the real one (#107).
    func challengeQuietSocket(_ socket: any HostEventsSocketing) {
        guard watchdogPing == nil else { return }
        watchdogPingGeneration += 1
        let generation = watchdogPingGeneration
        let payload = Self.challengePayload()
        watchdogPing = Task { [weak self, weak socket] in
            try? await socket?.ping(payload: payload)
            guard let self, watchdogPingGeneration == generation else { return }
            watchdogPing = nil
        }
    }

    func cancelWatchdogPing() {
        watchdogPing?.cancel()
        watchdogPing = nil
        watchdogPingGeneration += 1
    }
}
