import Foundation

// The terminal's liveness check: one round at a time, bounded twice. The
// send bound asks whether the outbound queue drained; the pong bound asks
// whether the host replied. A pong proves only the second, so the two are
// separate handles under separate tokens (#107). The controller decides
// what a miss means through `onTimeout`.
@MainActor
final class TerminalHeartbeat {
    private let policy: HeartbeatPolicy
    private let timing: ConnectionTiming
    private var send: (@MainActor (String, Int) -> Task<Void, Never>?)?
    private var isCurrent: (@MainActor (Int) -> Bool)?
    private var onSent: (@MainActor () -> Void)?
    private var onTimeout: (@MainActor (TerminalRecoveryReason) -> Void)?

    private var loop: Task<Void, Never>?
    private var sendBound: Task<Void, Never>?
    private var pongBound: Task<Void, Never>?
    private var outstandingPongID: String?
    private var outstandingSendID: String?

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
        stop()
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

    // Both bounds and the tokens they answer to, released together.
    func stop() {
        loop?.cancel()
        loop = nil
        sendBound?.cancel()
        sendBound = nil
        pongBound?.cancel()
        pongBound = nil
        outstandingPongID = nil
        outstandingSendID = nil
    }

    // A reply releases the pong bound only: it says nothing about our own
    // queue draining, and sitting the budget out made a healthy cadence
    // interval + timeout.
    func pongReceived(_ identifier: String) {
        guard outstandingPongID == identifier else { return }
        outstandingPongID = nil
        pongBound?.cancel()
        pongBound = nil
    }

    // A satisfied path change restarts the heartbeat under the same
    // generation, so `isCurrent` — whose check includes this task's
    // cancellation — is what stops a superseded round before it writes the
    // live round's handles.
    private func beat(generation: Int) async {
        guard !Task.isCancelled else { return }
        let identifier = UUID().uuidString
        outstandingPongID = identifier
        outstandingSendID = identifier
        let sendBound = bound(generation, policy.sendTimeout, .heartbeatSendStalled) {
            $0.outstandingSendID == identifier
        }
        self.sendBound = sendBound
        await send?(identifier, generation)?.value
        sendBound.cancel()
        guard isCurrent?(generation) == true, outstandingSendID == identifier else { return }
        outstandingSendID = nil
        self.sendBound = nil
        onSent?()
        guard outstandingPongID == identifier else { return }
        let pongBound = bound(generation, policy.timeout, .heartbeatPongMissing) {
            $0.outstandingPongID == identifier
        }
        self.pongBound = pongBound
        await pongBound.value
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
