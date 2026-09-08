import Foundation
import os

// What the network path is worth to a live terminal. The monitor speaks for
// the interface, not for the socket: a link that goes away ends the session's
// patience, a link that comes back is a reason to dial now, and an interface
// change is only a reason to ask. Carved out of `TerminalSessionController`
// unchanged (#111 P2).
extension TerminalSessionController {
    func handlePath(_ event: NetworkPathWatch.Event) {
        guard configuration != nil, shouldReconnect, connectionState != .suspended else { return }

        switch event {
        case .lost:
            Self.logger.info("network path lost: generation=\(self.connectionGeneration)")
            transition(.networkLost)
            // Keep the retry loop alive so recovery never depends on the
            // monitor delivering a satisfied event later.
            connectionEndedUnexpectedly(.networkPathLost)
        case let .restored(from, to):
            logPath(from: from, to: to)
            // A network that comes back is a real signal: dial now rather
            // than waiting out the retry. The attempt count stays.
            if connectionState == .connected { askHeartbeat() } else { beginConnection() }
        case let .changed(from, to):
            logPath(from: from, to: to)
            // Only ask: an interface change is chatter, and a dial in
            // progress keeps its ready budget — restarting it on every
            // change never let a slow host finish (#107).
            if connectionState == .connected { askHeartbeat() }
        }
    }

    private func logPath(from: NetworkPathSnapshot, to: NetworkPathSnapshot) {
        Self.logger.info(
            "network path restored or changed (\(from.interfaceIdentity) -> \(to.interfaceIdentity))"
        )
    }

    // A socket is judged by its own heartbeat (#86, PRD §7.13): most cellular
    // handovers leave a working socket working, so it is asked rather than
    // torn down.
    private func askHeartbeat() {
        heartbeat.start(generation: connectionGeneration, immediately: true)
    }
}
