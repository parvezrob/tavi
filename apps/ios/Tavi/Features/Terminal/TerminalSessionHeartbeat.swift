import Foundation

// The terminal's liveness check, kept beside the controller rather than in
// it: one round at a time, bounded twice, and the only part of #107 with a
// schedule of its own. The controller still owns the connection and decides
// what a miss means — `heartbeatDidTimeOut` is the single way back in.
extension TerminalSessionController {
    func startHeartbeat(generation: Int, immediately: Bool = false) {
        heartbeatTask?.cancel()
        clearHeartbeatBounds()
        var skipFirstWait = immediately
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    if skipFirstWait {
                        skipFirstWait = false
                    } else {
                        try await timing.sleep(heartbeatPolicy.interval)
                    }
                } catch {
                    return
                }
                guard let self,
                      isCurrentConnection(generation),
                      connectionState == .connected else { return }
                await beat(generation: generation)
                guard isCurrentConnection(generation) else { return }
            }
        }
    }

    // One round, bounded twice and owned twice. The send bound asks whether
    // the outbound queue drained; the answer bound asks whether the host
    // replied. They are separate handles under separate tokens because a
    // pong proves only the second: a queue that never drains leaves the
    // terminal accepting input that cannot leave, which is the wedge #107
    // exists to remove. A satisfied path change restarts the heartbeat under
    // the *same* generation, so `isCurrentConnection` — whose check includes
    // this task's cancellation — is what stops a superseded round before it
    // writes the live round's handles.
    private func beat(generation: Int) async {
        guard !Task.isCancelled else { return }
        let identifier = UUID().uuidString
        outstandingHeartbeatID = identifier
        outstandingHeartbeatSendID = identifier
        let sendBound = bound(generation, heartbeatPolicy.sendTimeout, .heartbeatSendStalled) {
            $0.outstandingHeartbeatSendID == identifier
        }
        heartbeatSendBound = sendBound
        await outbound.send(.ping(identifier: identifier), generation: generation).value
        sendBound.cancel()
        // The send returned, whatever the host has or has not said. Only
        // this round may retire its own token.
        guard isCurrentConnection(generation), outstandingHeartbeatSendID == identifier else { return }
        outstandingHeartbeatSendID = nil
        heartbeatSendBound = nil
        reconcileGridIfNeeded()
        guard outstandingHeartbeatID == identifier else { return }
        let pongBound = bound(generation, heartbeatPolicy.timeout, .heartbeatPongMissing) {
            $0.outstandingHeartbeatID == identifier
        }
        heartbeatDeadlineTask = pongBound
        await pongBound.value
    }

    private func bound(
        _ generation: Int,
        _ duration: Duration,
        _ reason: TerminalRecoveryReason,
        while isOutstanding: @escaping @Sendable @MainActor (TerminalSessionController) -> Bool
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                try await timing.sleep(duration)
            } catch {
                return
            }
            guard let self, isCurrentConnection(generation), isOutstanding(self) else { return }
            heartbeatDidTimeOut(reason)
        }
    }
}
