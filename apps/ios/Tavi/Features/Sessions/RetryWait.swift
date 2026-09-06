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
// And one this type asks of its timing: `sleep` must suspend before it
// returns (the live clock and the manual test clock both do), because the
// timer is started before the continuation is registered — a sleep that
// returned synchronously would release nothing and the wait would hang
// until cancellation.
@MainActor
final class RetryWait {
    private let timing: ConnectionTiming
    // The wait in progress, numbered so a timer or a cancellation callback
    // that arrives late can only release the wait it was started for.
    private var pending: (id: Int, continuation: CheckedContinuation<Void, Never>)?
    private var lastID = 0
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
        lastID += 1
        let id = lastID
        let timer = Task { [weak self, timing] in
            try? await timing.sleep(delay)
            guard !Task.isCancelled else { return }
            self?.release(id)
        }
        defer { timer.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                pending = (id, continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(id) }
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

    // Without an id, whatever wait is pending; with one, only that wait.
    private func release(_ id: Int? = nil) {
        guard let pending, id == nil || pending.id == id else { return }
        self.pending = nil
        pending.continuation.resume()
    }
}
