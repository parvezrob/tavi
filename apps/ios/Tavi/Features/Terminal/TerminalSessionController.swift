import Foundation
import Observation
import os

@MainActor
@Observable
final class TerminalSessionController {
    static let logger = Logger(subsystem: "com.farfield.tavi", category: "terminal.connection")

    private(set) var connectionState: TerminalConnectionState = .idle
    private(set) var errorMessage: String?
    var firstPaintMilliseconds: Double? { metrics.firstPaintMilliseconds }
    var inputToOutputMilliseconds: Double? { metrics.inputToOutputMilliseconds }
    // One deliberate attach; the view keys the renderer to it, so Jump-to
    // gets a clean surface and an ordinary reconnect keeps the one on screen.
    private(set) var sessionID = 0
    // The renderer's accessibility transcript, read by "Files mentioned"
    // (#61) when the sheet opens. Unobserved on purpose: it republishes 4×/s
    // and would invalidate the whole terminal screen every time (#68).
    @ObservationIgnored private(set) var latestTranscript = ""
    // Localhost ports the transcript names, for the Preview button (#58).
    var mentionedPorts: [Int] { mentioned.ports }

    let bridge = TerminalIOBridge()

    private let client: any TerminalTransporting
    let heartbeat: TerminalHeartbeat
    private let mentioned = MentionedPorts()
    private let grid = TerminalGridSync()
    private let outbound: TerminalOutbound
    private let pathWatch: NetworkPathWatch
    private let reconnectPolicy: ReconnectPolicy
    private let timing: ConnectionTiming

    var configuration: TerminalConnectionConfiguration?
    private var connectDeadlineTask: Task<Void, Never>?
    var connectionGeneration = 0
    private var disconnectTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var isSceneActive = true
    @ObservationIgnored private var metrics = TerminalLatencyMetrics()
    // When the current connection last said ready; nil while it is not up.
    private var readyAt: ContinuousClock.Instant?
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    // Where this terminal's recoveries are recorded (#111); nil records nothing.
    private var recovery: RecoveryLog?
    var shouldReconnect = false
    // The log's accepted offset is `resumePoint` and nothing else, so every
    // place it moves or is dropped says so once; `requestedResume` is what the
    // dial asked for, so a `ready` at another point is caught even when output
    // arrives first. Both unobserved: private, and the offset moves per chunk (#111).
    @ObservationIgnored private var requestedResume: TerminalResumePoint?
    @ObservationIgnored private var resumePoint: TerminalResumePoint? {
        didSet { recovery?.noteAcceptedOffset(resumePoint?.offset) }
    }

    init(
        client: any TerminalTransporting = TerminalWebSocketClient(),
        reconnectPolicy: ReconnectPolicy = .terminalDefault,
        heartbeatPolicy: HeartbeatPolicy = .terminalDefault,
        timing: ConnectionTiming = .live,
        pathObserver: any NetworkPathObserving = NetworkPathObserver()
    ) {
        self.client = client
        heartbeat = TerminalHeartbeat(policy: heartbeatPolicy, timing: timing)
        outbound = TerminalOutbound(client: client)
        pathWatch = NetworkPathWatch(observer: pathObserver)
        self.reconnectPolicy = reconnectPolicy
        self.timing = timing
        grid.install(outbound: outbound) { [weak self] in self?.connectionGeneration ?? 0 }
        outbound.installGenerationCheck { [weak self] generation in
            self?.isCurrentConnection(generation) ?? false
        }
        outbound.installOutcomeConsumer { [weak self] outcome in
            self?.handle(outcome)
        }
        heartbeat.install(
            send: { [weak self] identifier, generation in
                self?.outbound.send(.ping(identifier: identifier), generation: generation)
            },
            isCurrent: { [weak self] generation in
                guard let self else { return false }
                return isCurrentConnection(generation) && connectionState == .connected
            },
            onSent: { [weak self] in self?.reconcileGridIfNeeded() },
            onTimeout: { [weak self] reason in self?.heartbeatDidTimeOut(reason) }
        )
        bridge.installInputConsumer { [weak self] data in
            self?.deliverTerminalInput(data)
        }
        bridge.installRendererConsumer { [weak self] change in
            self?.handleRendererChange(change)
        }
    }

    func connect(hostText: String, paneID: String, credential: String, recovery: RecoveryLog? = nil) {
        do {
            guard let url = URL(string: hostText) else {
                throw HostEndpointError.invalidURL
            }
            let host = try HostEndpoint(baseURL: url)
            let configuration = try TerminalConnectionConfiguration(
                host: host,
                paneID: paneID,
                credential: credential
            )
            self.configuration = configuration
            // Before `resumePoint` is cleared below: its `didSet` tells the log.
            self.recovery = recovery
            errorMessage = nil
            shouldReconnect = true
            reconnectAttempt = 0
            resumePoint = nil
            metrics.reset()
            sessionID += 1
            // Cleared now, or Files mentioned and the Preview button answer
            // for the previous pane until the new surface draws (#108).
            latestTranscript = ""
            mentioned.clear()
            bridge.beginSession(sessionID)
            pathWatch.start { [weak self] event in self?.handlePath(event) }
            beginConnection()
        } catch {
            errorMessage = error.localizedDescription
            if configuration == nil {
                transition(.unrecoverableFailure)
            }
        }
    }

    func stop() {
        pathWatch.stop()
        mentioned.clear()
        endSession(.stop)
    }

    func sceneDidBecomeActive() {
        isSceneActive = true
        resumeSessionIfReady()
    }

    func sceneWillResignActive() {
        isSceneActive = false
        pauseSession()
    }

    func paste(_ text: String) {
        guard connectionState.canSubmitInput else {
            errorMessage = "Wait for the terminal to reconnect before pasting."
            return
        }
        guard !text.isEmpty else { return }
        let bracketedPaste = "\u{1B}[200~\(text)\u{1B}[201~"
        deliverTerminalInput(Data(bracketedPaste.utf8), canCoalesce: false)
    }

    var needsConnectionConfiguration: Bool {
        configuration == nil
    }

    // Identity of the connected pane, for the terminal header and the
    // Jump-to sheet's "Current" badge.
    var currentPaneID: String? {
        configuration?.paneID
    }

    func sendQuickKey(_ key: TerminalQuickKey) {
        guard connectionState.canSubmitInput else { return }
        deliverTerminalInput(Data(key.sequence.utf8))
    }

    // One-shot Ctrl modifier for the quick-key row.
    var controlLatchActive: Bool { outbound.controlLatchActive }

    func toggleControlLatch() {
        outbound.toggleControlLatch()
    }

    // Deliberate composer send for terminal targets: the text travels as a
    // bracketed paste (so embedded newlines cannot self-execute) followed
    // by a single explicit return.
    func sendComposedText(_ text: String) {
        guard connectionState.canSubmitInput else {
            errorMessage = "Wait for the terminal to reconnect before sending."
            return
        }
        guard !text.isEmpty else { return }
        paste(text)
        deliverTerminalInput(Data("\r".utf8), canCoalesce: false)
    }

    func transcriptDidChange(_ value: String) {
        latestTranscript = value
        mentioned.update(from: value)
    }

    func terminalGridDidChange(_ size: TerminalGridSize) {
        grid.gridDidChange(
            to: size,
            canSend: connectionState.canSubmitInput,
            whileIn: String(describing: connectionState)
        )
    }

    func terminalRendererDidAttach() {
        grid.sendLatest(canSend: connectionState.canSubmitInput)
    }

    func rendererDidFail(_ message: String) {
        errorMessage = message
        endSession(.unrecoverableFailure)
    }

    // The host sends up to three takeover signals; the first ends the session
    // and the rest change nothing. Opening the agent again is the way back.
    func handleTakeover() {
        guard connectionState != .superseded else { return }
        Self.logger.info("attachment taken over by another connection")
        record(.takenOver)
        endSession(.takenOver)
    }

    #if DEBUG
        func renderDevelopmentOutput(_ value: String) {
            bridge.receiveRemoteOutput(Data(value.utf8))
        }
    #endif

    func beginConnection() {
        guard shouldReconnect, let configuration else { return }
        eventTask?.cancel()
        heartbeat.stop()
        readyAt = nil
        outbound.cancel()
        // Cancelled and released: a retained handle kept the retry gate in
        // connectionEndedUnexpectedly() shut for good (#107).
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionGeneration += 1
        let generation = connectionGeneration
        let pendingDisconnect = disconnectTask
        transition(.connect)
        recovery?.tally(.dial, source: .terminal)
        metrics.connectionStarted(at: timing.now())
        startConnectDeadline(generation: generation)

        eventTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let pendingDisconnect {
                    await pendingDisconnect.value
                }
                guard isCurrentConnection(generation) else { return }
                await client.disconnect()
                guard isCurrentConnection(generation) else { return }
                requestedResume = resumePoint
                try await client.connect(configuration: configuration, resume: resumePoint)
                while isCurrentConnection(generation) {
                    let event = await client.receive()
                    guard isCurrentConnection(generation) else { return }
                    handle(event)
                    switch event {
                    case .message:
                        continue
                    case .disconnected, .failed, .takenOver:
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch let error as TerminalTransportError {
                guard isCurrentConnection(generation) else { return }
                if error.isPermanentConnectionFailure {
                    failPermanently(error)
                } else {
                    connectionEndedUnexpectedly(.transportFailed)
                }
            } catch {
                guard isCurrentConnection(generation) else { return }
                connectionEndedUnexpectedly(.transportFailed)
            }
        }
    }

    private func handle(_ event: TerminalTransportEvent) {
        switch event {
        case let .message(message):
            handle(message)
        case .disconnected:
            connectionEndedUnexpectedly(.transportDisconnected)
        case .takenOver:
            handleTakeover()
        case let .failed(error):
            if error.isPermanentConnectionFailure {
                failPermanently(error)
            } else {
                connectionEndedUnexpectedly(.transportFailed)
            }
        }
    }

    private func handle(_ message: TerminalServerMessage) {
        guard !message.isTakeoverNotice else {
            handleTakeover()
            return
        }
        switch message {
        case let .ready(stream, offset, resumed):
            connectDeadlineTask?.cancel()
            connectDeadlineTask = nil
            // A ready during the retry delay is a success, not a straggler (#107).
            reconnectTask?.cancel()
            reconnectTask = nil
            errorMessage = nil
            grid.forgetWhatWasSent()
            // Against what this dial asked for, not against where the stream
            // has since got to: recorded, never enforced (#111).
            let matched = requestedResume.map { $0.stream == stream && $0.offset == offset } ?? false
            resumePoint = stream.map { TerminalResumePoint(stream: $0, offset: offset) }
            readyAt = timing.now()
            let elapsed = metrics.connectionStartedAt.map { $0.milliseconds(to: timing.now()) } ?? 0
            Self.logger.info("ready: generation=\(self.connectionGeneration) attempt=\(self.reconnectAttempt) resumed=\(resumed) afterMs=\(Int(elapsed))")
            recovery?.tally(resumed ? (matched ? .resumeHit : .resumeMismatch) : .resumeMiss, source: .terminal)
            record(.ready, resumed: resumed)
            transition(.ready)
            grid.sendLatest()
            heartbeat.start(generation: connectionGeneration)
        case let .output(text):
            metrics.outputArrived(at: timing.now())
            bridge.receiveRemoteOutput(Data(text.utf8))
        case let .outputChunk(offset, data):
            metrics.outputArrived(at: timing.now())
            // A stream that is not contiguous says so before the chunk is taken;
            // P1 observes only, so the chunk is accepted as it always was (#111).
            if let expected = resumePoint?.offset, offset != expected {
                record(offset > expected ? .offsetGap : .offsetOverlap)
            }
            // The offset the host may trim behind moves only for bytes a live
            // surface has queued; the bridge answers synchronously (#108).
            if bridge.receiveRemoteOutput(data) {
                resumePoint?.advance(to: offset + UInt64(data.count))
            }
        case let .pong(identifier):
            // A path change turns the round in flight into the handover
            // check; an answer inside its deadline is the evidence the
            // socket survived the move (#111 P2).
            if heartbeat.pongReceived(identifier) { record(.handoverChecked) }
        case .exit:
            endSession(.terminalExited)
        case let .error(message, _):
            errorMessage = message
        }
    }

    private func handleRendererChange(_ change: TerminalIOBridge.RendererChange) {
        switch change {
        case .attached:
            resumeSessionIfReady()
        case .detached:
            // Whatever that surface accepted went with it.
            resumePoint = nil
            pauseSession()
        case .outputDiscarded:
            resumePoint = nil
            Self.logger.info("output discarded; the resume epoch is over")
            record(.outputDiscarded)
            guard bridge.hasRenderer else {
                pauseSession()
                return
            }
            // No input over a screen with a hole in it: cycle, repaint first.
            connectionEndedUnexpectedly(.outputDiscarded)
        }
    }

    private func pauseSession() {
        guard configuration != nil else { return }
        shouldReconnect = false
        invalidateConnectionTasks()
        scheduleDisconnect()
        transition(.suspend)
    }

    // Both owners must be present: the scene in front of the person and a
    // surface to paint into. A superseded session never reaches .suspended.
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

    func connectionEndedUnexpectedly(_ reason: TerminalRecoveryReason) {
        guard shouldReconnect, connectionState != .suspended, connectionState != .ended else {
            return
        }
        guard reconnectTask == nil else {
            Self.logger.info("cycle ignored, retry pending: reason=\(reason.rawValue, privacy: .public) generation=\(self.connectionGeneration)")
            return
        }

        connectDeadlineTask?.cancel()
        connectDeadlineTask = nil
        heartbeat.stop()
        // The backoff forgets only after a connection held for the documented
        // period, so flaps cannot walk the delay back to its shortest (#107).
        if let readyAt, readyAt.duration(to: timing.now()) >= reconnectPolicy.sustainedHealthInterval {
            reconnectAttempt = 0
        }
        readyAt = nil
        reconnectAttempt += 1
        if pathWatch.current?.isSatisfied == false {
            transition(.networkLost)
        } else {
            transition(.connectionLost(nextAttempt: reconnectAttempt))
        }
        let delay = reconnectPolicy.delay(forAttempt: reconnectAttempt)
        let generation = connectionGeneration
        let timing = timing
        // The reason is a closed enum of fixed tokens, so it can be public.
        Self.logger.info(
            "cycling: reason=\(reason.rawValue, privacy: .public) generation=\(generation) attempt=\(self.reconnectAttempt) delayMs=\(delay.wholeMilliseconds)"
        )
        // Recorded before the retry cancels anything the transport is still
        // holding: the cause belongs to the connection that had it (#111).
        record(.cycling, reason: .terminal(reason))
        reconnectTask = Task { [weak self] in
            do {
                try await timing.sleep(delay)
            } catch {
                return
            }
            guard let self, shouldReconnect, isCurrentConnection(generation) else { return }
            // No await before the dial: beginConnection() bumps the generation
            // first, so the old loop's report of the close is discarded (#107).
            reconnectTask = nil
            beginConnection()
        }
    }

    private func startConnectDeadline(generation: Int) {
        connectDeadlineTask?.cancel()
        let deadline = reconnectPolicy.connectDeadline
        let timing = timing
        connectDeadlineTask = Task { [weak self] in
            do {
                try await timing.sleep(deadline)
            } catch {
                return
            }
            guard let self,
                  isCurrentConnection(generation),
                  connectionState == .connecting else { return }
            connectionEndedUnexpectedly(.connectDeadline)
        }
    }

    // Either heartbeat bound expiring says the same thing to the person;
    // which one it was is in the log.
    private func heartbeatDidTimeOut(_ reason: TerminalRecoveryReason) {
        errorMessage = "The host stopped responding. Reconnecting."
        // Named before the cycle it causes, so the log says the handover was
        // what this connection failed rather than an ordinary quiet host.
        switch reason {
        case .handoverPongMissing, .handoverSendStalled:
            record(.handoverFailed, reason: .terminal(reason))
        default:
            break
        }
        connectionEndedUnexpectedly(reason)
    }

    private func deliverTerminalInput(_ data: Data, canCoalesce: Bool = true) {
        guard connectionState.canSubmitInput, !data.isEmpty else { return }
        metrics.inputSent(at: timing.now())
        outbound.submitInput(data, generation: connectionGeneration, canCoalesce: canCoalesce)
    }

    private func handle(_ outcome: TerminalOutbound.Outcome) {
        switch outcome {
        case let .sent(message):
            guard case let .resize(columns, rows) = message else { return }
            grid.didSend(columns: columns, rows: rows)
            Self.logger.info("resize \(columns)x\(rows) sent to host")
        case let .failed(error, inputWasSubmitted):
            if error == .oversizedFrame {
                errorMessage = error?.localizedDescription
                metrics.inputAbandoned()
                return
            }
            if inputWasSubmitted {
                // An unnamed transport failure is as uncertain as delivery
                // gets: never say the input was not sent when it may have been.
                errorMessage = error == nil || error == .deliveryUncertain
                    ? TerminalTransportError.deliveryUncertain.localizedDescription
                    : "Input was not sent."
                metrics.inputAbandoned()
            }
            connectionEndedUnexpectedly(.outboundFailed)
        case .drained:
            reconcileGridIfNeeded()
        case .backedUp:
            errorMessage = "Terminal input is backed up. Wait for the connection to catch up."
        }
    }

    // Every terminal record carries the same three: which connection it was,
    // which attempt, and how long that connection had been up (#111).
    private func record(_ kind: RecoveryLog.Kind, reason: RecoveryLog.Reason = .none, resumed: Bool? = nil) {
        let held = Int(metrics.connectionStartedAt?.milliseconds(to: timing.now()) ?? 0)
        recovery?.record(
            kind, source: .terminal, reason: reason, generation: connectionGeneration,
            attempt: reconnectAttempt, elapsedMilliseconds: held, resumed: resumed
        )
    }

    func transition(_ action: TerminalConnectionAction) {
        connectionState = TerminalConnectionReducer.reduce(connectionState, action: action)
    }

    private func invalidateConnectionTasks() {
        connectionGeneration += 1
        connectDeadlineTask?.cancel()
        connectDeadlineTask = nil
        eventTask?.cancel()
        heartbeat.stop()
        outbound.cancel()
        reconnectTask?.cancel()
        eventTask = nil
        reconnectTask = nil
        readyAt = nil
        metrics.inputAbandoned()
        grid.forgetWhatWasSent()
    }

    private func isCurrentConnection(_ generation: Int) -> Bool {
        generation == connectionGeneration && !Task.isCancelled
    }

    private func scheduleDisconnect() {
        guard disconnectTask == nil else { return }
        let client = client
        disconnectTask = Task { [weak self] in
            await client.disconnect()
            self?.disconnectTask = nil
        }
    }

    private func reconcileGridIfNeeded() {
        grid.reconcileIfNeeded(canSend: connectionState.canSubmitInput, isIdle: outbound.isIdle)
    }

    private func failPermanently(_ error: TerminalTransportError) {
        errorMessage = error.localizedDescription
        endSession(.unrecoverableFailure)
    }

    // Every way a session ends for good: nothing is retried, no resume point
    // survives it, and the socket is closed exactly once.
    private func endSession(_ action: TerminalConnectionAction) {
        shouldReconnect = false
        configuration = nil
        resumePoint = nil
        bridge.discardPendingOutput()
        invalidateConnectionTasks()
        scheduleDisconnect()
        transition(action)
    }
}
