import Foundation
import os

// Who owns this terminal, kept beside the controller rather than in it
// (#108). Two ownerships meet: the host gives a pane's attachment to one
// connection at a time, and one renderer surface at a time owns the byte
// stream the resume offset points into. The controller still owns dialling,
// retries and the socket; this file decides when a resume point is still
// worth having and when the session may be running at all.
extension TerminalSessionController {
    private static let logger = Logger(subsystem: "com.farfield.tavi", category: "terminal.attachment")

    // MARK: - The host's ownership

    // Idempotent: three signals carry the same outcome and any one may
    // arrive first. endSession drops the configuration, the resume point and
    // the queued input together, so nothing reclaims the pane and no
    // keystroke is replayed. The agent is still running; connect() — back,
    // then open it again — is the way in.
    func handleTakeover() {
        guard connectionState != .superseded else { return }
        Self.logger.info("attachment taken over by another connection")
        endSession(.takenOver)
    }

    // MARK: - The surface's ownership

    // The offset the host may trim behind means: bytes durably queued, in
    // order, for a surface that is still alive — not a frame on the screen.
    // The bridge answers synchronously, so no acknowledgement waits on a
    // renderer callback, and a refusal leaves the offset where it was.
    func acceptOutput(offset: UInt64, data: Data) {
        guard bridge.receiveRemoteOutput(data) else { return }
        resumePoint?.advance(to: offset + UInt64(data.count))
    }

    func handleRendererChange(_ change: TerminalIOBridge.RendererChange) {
        switch change {
        case .attached:
            resumeSessionIfReady()
        case .detached:
            // Whatever that surface accepted went with it, and there is
            // nobody left to paint for.
            discardResumePoint()
            pauseSession()
        case .outputDiscarded:
            discardResumePoint()
            Self.logger.info("output discarded; the resume epoch is over")
            guard bridge.hasRenderer else {
                pauseSession()
                return
            }
            // No input may go out over a screen with a hole in it, so the
            // socket is cycled now and the fresh attach repaints first.
            connectionEndedUnexpectedly(.outputDiscarded)
        }
    }

    // MARK: - When the session may be live

    func sceneDidBecomeActive() {
        isSceneActive = true
        resumeSessionIfReady()
    }

    func sceneWillResignActive() {
        isSceneActive = false
        pauseSession()
    }

    // Nil is a fresh attach, which is how the host is asked to repaint.
    private func discardResumePoint() {
        resumePoint = nil
    }

    private func pauseSession() {
        guard configuration != nil else { return }
        shouldReconnect = false
        invalidateConnectionTasks()
        scheduleDisconnect()
        transition(.suspend)
    }

    // Both owners have to be present: the scene in front of the person, and
    // a surface to paint into. A superseded session never reaches
    // .suspended, so nothing here can reclaim a terminal this client lost.
    private func resumeSessionIfReady() {
        guard connectionState == .suspended,
              configuration != nil,
              isSceneActive,
              bridge.hasRenderer else { return }
        shouldReconnect = true
        reconnectAttempt = 0
        transition(.resume)
        beginConnection()
    }
}
