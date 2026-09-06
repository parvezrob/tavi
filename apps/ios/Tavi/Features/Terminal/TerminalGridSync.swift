import Foundation
import os

// Keeping the host's pty the size of the grid on screen. The rendered grid
// changes for reasons the connection knows nothing about (rotation, the
// keyboard, a font change), and a resize send can be lost or deferred, so
// the last size sent is remembered and the two are reconciled whenever the
// outbound queue is idle. Carved out of `TerminalSessionController`
// unchanged (#101, #111 P4).
@MainActor
final class TerminalGridSync {
    private static let logger = Logger(subsystem: "com.farfield.tavi", category: "terminal.connection")

    // The grid the surface last reported, which is what the host must
    // converge on.
    private(set) var latest: TerminalGridSize?

    private var lastSent: TerminalGridSize?
    private var outbound: TerminalOutbound?
    private var generation: () -> Int = { 0 }

    // The queue this size travels on, and which connection it belongs to:
    // a resize from a superseded connection is dropped by the queue itself.
    func install(outbound: TerminalOutbound, generation: @escaping () -> Int) {
        self.outbound = outbound
        self.generation = generation
    }

    // A new connection has sent nothing yet, so nothing it might resend is
    // "already sent".
    func forgetWhatWasSent() {
        lastSent = nil
    }

    // A grid the surface reports is always remembered; whether it can be
    // sent now is the connection's to say, and a deferred one is picked up
    // by the next reconcile.
    func gridDidChange(to size: TerminalGridSize, canSend: Bool, whileIn state: String) {
        guard size != latest else { return }
        latest = size
        guard canSend else {
            Self.logger.info("grid change \(size.columns)x\(size.rows) deferred: cannot submit input in \(state)")
            return
        }
        Self.logger.info("grid change \(size.columns)x\(size.rows) queued for send")
        send(size)
    }

    // A surface that just attached, and a connection that just said ready,
    // both need the host pointed at the grid on screen.
    func sendLatest(canSend: Bool = true) {
        guard canSend, let latest else { return }
        send(latest)
    }

    func didSend(columns: Int, rows: Int) {
        lastSent = TerminalGridSize(columns: columns, rows: rows)
    }

    // Checked after the outbound queue drains and on every heartbeat: the
    // host's grid must converge on the latest rendered one even when a
    // resize send was lost or deferred.
    func reconcileIfNeeded(canSend: Bool, isIdle: Bool) {
        guard canSend, isIdle, let latest, latest != lastSent else { return }
        Self.logger.info("reconciling grid to \(latest.columns)x\(latest.rows)")
        send(latest)
    }

    private func send(_ size: TerminalGridSize) {
        outbound?.send(.resize(columns: size.columns, rows: size.rows), generation: generation())
    }
}
