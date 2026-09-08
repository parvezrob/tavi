import Foundation

// The one handover challenge a link can have outstanding: what it sent, when
// it went, and the two facts its deadline judges — whether the matching pong
// came back (latched, so a later unrelated pong cannot unsay it) and whether
// the send itself ever finished (#111).
struct HandoverChallenge {
    let payload: Data
    let dial: Int
    let startedAt: ContinuousClock.Instant
    // The one absolute budget, fixed at the path change: the bound task fires
    // at it, and a pong read after it is late whether or not that task has
    // run yet (#111).
    let expiresAt: ContinuousClock.Instant
    var answered = false
    var sendCompleted = false
}

// What the phone's own network is doing to a link that is up: the 2 s check
// on a new interface, and what a path that goes and comes back means for a
// socket the link still holds (#111 P2).
extension HostConnection {
    // One absolute budget from the path change, covering send and pong.
    static let handoverDeadline: Duration = .seconds(2)

    // What the phone's own network did, and what this link does about it
    // (#111). A satisfied→satisfied change means a new interface under a
    // socket that may already be dead, and nothing on the socket itself
    // would say so for 35 s.
    func pathChanged(_ event: NetworkPathWatch.Event) {
        switch event {
        case .changed:
            challengeHandover()
        case .restored:
            // The retained socket is waiting on a path that is gone: cut it
            // and dial now rather than sit out the rest of a ten second
            // delay. The attempt count and the epoch are kept — this is the
            // same outage, caught early, not a fresh start.
            if let socket {
                cycleSocket(socket, reason: .pathRestored, dial: epoch, attempt: reconnectAttempt, since: timing.now())
            }
            wakeRetry()
        case .lost:
            // The retry loop keeps its schedule: recovery may never depend
            // on a future path event. Only the Offline verdict waits, in
            // `setOffline`.
            markStale()
        }
    }

    // Coalesced: while a challenge is outstanding further path changes are
    // ignored, so the earliest deadline is the one that decides. A send still
    // in flight refuses one too — one challenge owns one send, and a second
    // ping on a socket whose first never returned would say nothing new. A
    // dial that has not delivered a frame yet is not established and keeps
    // its own budget untouched.
    func challengeHandover() {
        guard handover == nil, handoverSend == nil, streamConnectedAt != nil, let socket else { return }
        let dial = epoch
        let payload = Self.challengePayload()
        let startedAt = timing.now()
        handover = HandoverChallenge(
            payload: payload,
            dial: dial,
            startedAt: startedAt,
            expiresAt: startedAt.advanced(by: Self.handoverDeadline)
        )
        // Owned, not awaited: a send that never returns is what
        // `handover-send-stalled` names, and awaiting it here would hide the
        // deadline behind it (#107's defect). It stays owned past its own
        // challenge — cancelling the socket is what releases a real one — so
        // the slot carries the payload it belongs to and only that send frees
        // it.
        let send = Task { [weak self, weak socket] in
            try? await socket?.ping(payload: payload)
            guard let self else { return }
            if handover?.payload == payload { handover?.sendCompleted = true }
            if handoverSend?.payload == payload { handoverSend = nil }
        }
        handoverSend = (payload, send)
        handoverDeadline = Task { [weak self, timing] in
            try? await timing.sleep(Self.handoverDeadline)
            guard !Task.isCancelled, let self else { return }
            judgeHandover(dial: dial, payload: payload)
        }
    }

    // The 2 s are up. A challenge that was answered has already been
    // recorded; one that was not says which half failed and cycles, because
    // a socket that cannot answer on the new interface is dead however
    // quietly it failed.
    //
    // `dial == epoch` is defence in depth and nothing in this package can
    // reach it: three owners cancel this task before it could run late — the
    // dial's own defer, `stop()`, and the task's cancellation, which the
    // sleep above returns from. It stays so that a future caller arming a
    // bound without one of those owners still cannot cycle a replacement.
    private func judgeHandover(dial: Int, payload: Data) {
        guard let challenge = handover, challenge.payload == payload, dial == epoch else { return }
        clearHandover()
        guard !challenge.answered, let socket else { return }
        let miss: RecoveryLog.HandoverMiss = challenge.sendCompleted ? .pongMissing : .sendStalled
        let waited = Int(challenge.startedAt.milliseconds(to: timing.now()))
        recovery?.record(
            .handoverFailed,
            source: .events,
            reason: .handover(miss),
            generation: dial,
            attempt: reconnectAttempt,
            elapsedMilliseconds: waited
        )
        cycleSocket(socket, reason: .handover(miss), dial: dial, attempt: reconnectAttempt, since: challenge.startedAt)
    }

    // A pong answers this challenge only if it carries its payload and
    // arrives inside the budget: a late pong from an earlier watchdog ping
    // says nothing about the new interface, and a pong past the deadline
    // instant is a miss whether or not the bound task has run yet — the
    // budget is the clock's, not the task scheduler's. Latched, so nothing
    // arriving after a good one can unsay it.
    func pongArrived(_ payload: Data, dial: Int) {
        guard var challenge = handover, challenge.dial == dial, dial == epoch else { return }
        guard challenge.payload == payload, !challenge.answered else { return }
        guard timing.now() < challenge.expiresAt else { return }
        challenge.answered = true
        handover = challenge
        recovery?.record(
            .handoverChecked,
            source: .events,
            generation: dial,
            attempt: reconnectAttempt,
            elapsedMilliseconds: Int(challenge.startedAt.milliseconds(to: timing.now()))
        )
    }

    // The challenge is judged; the send it started outlives it, owned until
    // it returns or the socket is cancelled.
    func clearHandover() {
        handover = nil
        handoverDeadline?.cancel()
        handoverDeadline = nil
    }

    // The socket is going: everything the challenge holds goes with it, the
    // send included — this is the one thing that ends a send that ignores
    // cancellation, and it is why a stalled one cannot block the next dial.
    func cancelHandover() {
        clearHandover()
        handoverSend?.task.cancel()
        handoverSend = nil
    }
}
