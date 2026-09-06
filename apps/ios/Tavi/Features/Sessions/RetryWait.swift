import Foundation

// The retry delay between two dials, waited out or ended early. A signal
// that the network is back should redial now rather than sit out a ten
// second schedule (#111), and the signal can arrive before the dial it
// belongs to has finished unwinding — so one wake is remembered, tagged
// with the dial it was meant for, and the wait that follows that dial
// consumes it. A wake meant for an older dial is dropped there rather than
// spending itself on a later outage.
//
// Two invariants the owner supplies: one wait at a time, because
// HostConnection's stream task is the only caller and it sleeps once per
// dial; and a wake released against a *pending* wait needs no tag check,
// because the only two writers of `epoch` are `stop()` — which cancels the
// wait on the same turn — and `streamOnce`, which never runs while the loop
// is sleeping. The tag therefore only has to fence the remembered credit.
@MainActor
final class RetryWait {
    private let timing: ConnectionTiming
    private var pending: CheckedContinuation<Void, Never>?
    private var credit: Int?

    init(timing: ConnectionTiming) {
        self.timing = timing
    }

    // Returns once: when the delay elapses, when `wake` names this dial, or
    // when the calling task is cancelled.
    func sleep(_ delay: Duration, dial: Int) async {
        if let credit {
            self.credit = nil
            if credit == dial { return }
        }
        let timer = Task { [weak self, timing] in
            try? await timing.sleep(delay)
            guard !Task.isCancelled else { return }
            self?.release()
        }
        defer { timer.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                pending = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release() }
        }
    }

    func wake(dial: Int) {
        guard pending == nil else {
            release()
            return
        }
        credit = dial
    }

    func cancel() {
        credit = nil
        release()
    }

    private func release() {
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume()
    }
}
