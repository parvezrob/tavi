import Foundation

// The terminal's liveness check: one round at a time, bounded twice. The
// send bound asks whether the outbound queue drained; the pong bound asks
// whether the host replied. A pong proves only the second, so the two are
// separate handles under separate tokens (#107). The controller decides
// what a miss means through `onTimeout`.
//
// A network path change asks the round in flight rather than replacing it
// (#111 P2): its deadline becomes the earlier of its own and one `handover`
// from the change, that instant survives the send → pong transition, and a
// miss is reported as a handover miss. Only the absence of a round opens a
// new one, on the handover deadline.
@MainActor
final class TerminalHeartbeat {
    // The round in flight. Its deadline is an absolute instant so a path
    // change can shorten it without knowing which of the two bounds is
    // standing, and so a handover round can carry one budget across the send
    // → pong transition instead of opening a fresh one for the answer.
    private struct Round {
        let identifier: String
        var deadline: ContinuousClock.Instant
        var isHandover: Bool
        var isSendOutstanding = true
        var isPongOutstanding = true
    }

    private let policy: HeartbeatPolicy
    private let timing: ConnectionTiming
    private var send: (@MainActor (String, Int) -> Task<Void, Never>?)?
    private var isCurrent: (@MainActor (Int) -> Bool)?
    private var onSent: (@MainActor () -> Void)?
    private var onTimeout: (@MainActor (TerminalRecoveryReason) -> Void)?

    private var loop: Task<Void, Never>?
    private var sendBound: Task<Void, Never>?
    private var pongBound: Task<Void, Never>?
    private var round: Round?
    // Handed to the next round the loop opens: an ask that found no round in
    // flight is answered by a new one on the handover deadline.
    private var nextRoundIsHandover = false

    init(policy: HeartbeatPolicy, timing: ConnectionTiming) {
        self.policy = policy
        self.timing = timing
    }

    func install(
        send: @escaping @MainActor (String, Int) -> Task<Void, Never>?,
        isCurrent: @escaping @MainActor (Int) -> Bool,
        onSent: @escaping @MainActor () -> Void,
        onTimeout: @escaping @MainActor (TerminalRecoveryReason) -> Void
    ) {
        self.send = send
        self.isCurrent = isCurrent
        self.onSent = onSent
        self.onTimeout = onTimeout
    }

    func start(generation: Int, immediately: Bool = false) {
        // A round already under way is the handover check: restarting it
        // would throw away the evidence it has been gathering and hand the
        // socket a budget longer than the one the change deserves.
        if immediately, round != nil {
            askOutstandingRound(generation: generation)
            return
        }
        stop()
        nextRoundIsHandover = immediately
        var skipFirstWait = immediately
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    if skipFirstWait {
                        skipFirstWait = false
                    } else {
                        try await timing.sleep(policy.interval)
                    }
                } catch {
                    return
                }
                guard let self, isCurrent?(generation) == true else { return }
                await beat(generation: generation)
                guard isCurrent?(generation) == true else { return }
            }
        }
    }

    // Both bounds, the round they belong to and the tokens they answer to,
    // released together.
    func stop() {
        loop?.cancel()
        loop = nil
        sendBound?.cancel()
        sendBound = nil
        pongBound?.cancel()
        pongBound = nil
        round = nil
        nextRoundIsHandover = false
    }

    // A reply releases the pong bound only: it says nothing about our own
    // queue draining, and sitting the budget out made a healthy cadence
    // interval + timeout.
    //
    // True when it answered a round a path change had claimed — the handover
    // check the controller records (#111 P2).
    @discardableResult
    func pongReceived(_ identifier: String) -> Bool {
        guard var round, round.identifier == identifier, round.isPongOutstanding else { return false }
        round.isPongOutstanding = false
        self.round = round
        pongBound?.cancel()
        pongBound = nil
        return round.isHandover
    }

    // The round in flight becomes the handover check. Its deadline is never
    // lengthened, and a second change while it is outstanding leaves the
    // earliest one standing — the flapping that provoked the change usually
    // arrives several times.
    private func askOutstandingRound(generation: Int) {
        guard var round else { return }
        let target = timing.now().advanced(by: policy.handover)
        let isShortened = target < round.deadline
        // Nothing to re-arm when the round is already the handover check on
        // an earlier deadline than this change would give it.
        guard isShortened || !round.isHandover else { return }
        if isShortened { round.deadline = target }
        round.isHandover = true
        self.round = round
        rearmStandingBound(generation: generation, round: round)
    }

    // Whichever bound the round is standing on is replaced by one that
    // expires at the round's deadline and names a handover miss.
    private func rearmStandingBound(generation: Int, round: Round) {
        let identifier = round.identifier
        let remaining = remaining(to: round.deadline)
        if round.isSendOutstanding {
            sendBound?.cancel()
            sendBound = bound(generation, remaining, .handoverSendStalled) {
                $0.round?.identifier == identifier && $0.round?.isSendOutstanding == true
            }
        } else if round.isPongOutstanding {
            pongBound?.cancel()
            pongBound = bound(generation, remaining, .handoverPongMissing) {
                $0.round?.identifier == identifier && $0.round?.isPongOutstanding == true
            }
        }
    }

    private func beat(generation: Int) async {
        guard !Task.isCancelled else { return }
        let identifier = UUID().uuidString
        let isHandover = nextRoundIsHandover
        nextRoundIsHandover = false
        let budget = isHandover ? policy.handover : policy.sendTimeout
        round = Round(
            identifier: identifier,
            deadline: timing.now().advanced(by: budget),
            isHandover: isHandover
        )
        sendBound = bound(generation, budget, isHandover ? .handoverSendStalled : .heartbeatSendStalled) {
            $0.round?.identifier == identifier && $0.round?.isSendOutstanding == true
        }
        await send?(identifier, generation)?.value
        sendBound?.cancel()
        // A path change restarts the heartbeat under the same generation, so
        // `isCurrent` — whose check includes this task's cancellation — is
        // what stops a superseded round before it writes the live round's
        // handles.
        guard isCurrent?(generation) == true, round?.identifier == identifier,
              round?.isSendOutstanding == true else { return }
        round?.isSendOutstanding = false
        sendBound = nil
        onSent?()
        guard round?.isPongOutstanding == true else {
            round = nil
            return
        }
        armPongBound(generation: generation, identifier: identifier)
        // A path change can replace that bound with a shorter one, so the
        // round is over only once the bound still standing has finished.
        while let standing = pongBound {
            await standing.value
            guard pongBound == standing else { continue }
            pongBound = nil
            break
        }
        if round?.identifier == identifier { round = nil }
    }

    private func armPongBound(generation: Int, identifier: String) {
        guard var round, round.identifier == identifier else { return }
        // A handover round's answer is bounded by the round's own deadline:
        // the 2 s covers send and pong together, so a send that lands late
        // does not buy the host a fresh answer budget (#111 P2).
        let budget: Duration
        if round.isHandover {
            budget = remaining(to: round.deadline)
        } else {
            budget = policy.timeout
            round.deadline = timing.now().advanced(by: budget)
            self.round = round
        }
        pongBound = bound(generation, budget, round.isHandover ? .handoverPongMissing : .heartbeatPongMissing) {
            $0.round?.identifier == identifier && $0.round?.isPongOutstanding == true
        }
    }

    // A deadline already behind us is not a wait: it is a miss on the next
    // turn of the loop.
    private func remaining(to deadline: ContinuousClock.Instant) -> Duration {
        let remaining = timing.now().duration(to: deadline)
        return remaining > .zero ? remaining : .zero
    }

    private func bound(
        _ generation: Int,
        _ duration: Duration,
        _ reason: TerminalRecoveryReason,
        while isOutstanding: @escaping @Sendable @MainActor (TerminalHeartbeat) -> Bool
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                try await timing.sleep(duration)
            } catch {
                return
            }
            guard let self, isCurrent?(generation) == true, isOutstanding(self) else { return }
            onTimeout?(reason)
        }
    }
}
