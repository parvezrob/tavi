import Foundation

// How often the events watchdog looks at its socket, and the two idle marks
// it acts on (#86, #107). Tests cross the same marks on a manual clock.
struct HostWatchdogPolicy: Sendable, Equatable {
    let pollInterval: Duration
    let pingAfterIdle: Duration
    let cycleAfterIdle: Duration

    static let live = HostWatchdogPolicy(
        pollInterval: .seconds(5),
        pingAfterIdle: .seconds(30),
        cycleAfterIdle: .seconds(45)
    )
}

// One dial of the events stream, and every clock that can end it: the connect
// deadline, the watchdog, and what each of them tells the log. Carved out of
// `HostConnection` unchanged (#111 P2): the link owns its published state and
// its schedule, this owns the dial and the deadlines that cut it.
extension HostConnection {
    static let stableStreamInterval: Duration = .seconds(30)

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
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            if self.socket === socket { self.socket = nil }
        }

        armConnectDeadline(dial)
        defer { cancelConnectDeadline(dial) }

        let watchdog = startWatchdog(for: socket, dial: dial, attempt: attempt, since: dialledAt)
        defer {
            watchdog.cancel()
            // Only this dial's challenge: the `self.socket` defer above runs
            // after this one, so the identity check still holds here.
            if self.socket === socket { cancelWatchdogPing() }
        }

        var measured = false
        defer {
            // A dial that never produced a frame counts against the computer;
            // one that did resets the count. A cancelled dial still runs this,
            // by which time another computer may be in place.
            if dial == epoch {
                if measured { consecutiveFailedDials = 0 } else { consecutiveFailedDials += 1 }
                streamConnectedAt = nil
            }
        }
        do {
            while !Task.isCancelled {
                let frame = try await socket.receive()
                guard dial == epoch else { return }
                cancelConnectDeadline(dial)
                guard case let .string(text) = frame else { continue }
                if try apply(text, dial: dial, attempt: attempt, isFirst: !measured, dialledAt: dialledAt) {
                    measured = true
                }
            }
        } catch {
            guard !Task.isCancelled, dial == epoch else { return }
            // Before the `defer` closes the socket: the cause is this stream's (#111).
            noteStreamEnded(error, dial: dial, attempt: attempt, since: dialledAt)
        }
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

    // The cause belongs to the watchdog, not to the cancel it performs: the
    // catch below sees only a cancelled socket, a beat later (#111).
    func recordWatchdogCycle(dial: Int, attempt: Int, since: ContinuousClock.Instant) {
        watchdogCycledDial = dial
        let lasted = Int(since.milliseconds(to: timing.now()))
        recovery?.record(.cycling, source: .events, reason: .watchdog, generation: dial, attempt: attempt, elapsedMilliseconds: lasted)
    }

    // A stream end is both what happened and why the link cycles — unless the
    // watchdog already said why, in which case this is only what.
    func recordStreamEnd(_ failure: SocketFailure, dial: Int, attempt: Int, since: ContinuousClock.Instant) {
        let cause = RecoveryLog.Reason.socket(failure.tag, code: failure.code)
        let lasted = Int(since.milliseconds(to: timing.now()))
        recovery?.record(.streamEnded, source: .events, reason: cause, generation: dial, attempt: attempt, elapsedMilliseconds: lasted)
        guard watchdogCycledDial != dial else { return }
        recovery?.record(.cycling, source: .events, reason: cause, generation: dial, attempt: attempt, elapsedMilliseconds: lasted)
    }

    // Bounded "Connecting…": if nothing has arrived by the deadline, ask the
    // host directly; no answer is Offline, said now, while the attempt keeps
    // going in case it is merely slow. The first frame cancels this.
    func armConnectDeadline(_ dial: Int) {
        let deadline = reconnectPolicy.connectDeadline
        connectDeadlineTask?.cancel()
        connectDeadlineTask = Task { [weak self, timing] in
            try? await timing.sleep(deadline)
            guard !Task.isCancelled, let self else { return }
            let probe = await self.reachability.askTwice(self.reachabilityGeneration)
            guard !Task.isCancelled, dial == self.epoch else { return }
            // Earned, not guessed (#86): the first dial that fails is
            // "Connecting…" or "Reconnecting"; Offline waits for the next.
            if probe == .unreachable, self.consecutiveFailedDials >= 1 { self.setOffline(true, dial: dial) }
        }
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
                    recordWatchdogCycle(dial: dial, attempt: attempt, since: since)
                    socket.cancel(with: .goingAway, reason: nil)
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

    // One challenge in flight per link until the send actually finishes: a
    // send that ignores cancellation must not be multiplied by the next
    // quiet period. Cancelling the socket releases the real one (#107).
    func challengeQuietSocket(_ socket: any HostEventsSocketing) {
        guard watchdogPing == nil else { return }
        watchdogPingGeneration += 1
        let generation = watchdogPingGeneration
        watchdogPing = Task { [weak self, weak socket] in
            try? await socket?.ping()
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
