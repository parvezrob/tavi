import Foundation
import Observation
import os

@MainActor
@Observable
final class TerminalSessionController {
    private static let logger = Logger(subsystem: "com.farfield.tavi", category: "terminal.connection")

    private(set) var connectionState: TerminalConnectionState = .idle
    private(set) var errorMessage: String?
    var firstPaintMilliseconds: Double? { metrics.firstPaintMilliseconds }
    var inputToOutputMilliseconds: Double? { metrics.inputToOutputMilliseconds }
    private(set) var latestGridSize: TerminalGridSize?
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
    private let heartbeat: TerminalHeartbeat
    private let mentioned = MentionedPorts()
    private let outbound: TerminalOutbound
    private let pathWatch: NetworkPathWatch
    private let reconnectPolicy: ReconnectPolicy
    private let timing: ConnectionTiming

    private var configuration: TerminalConnectionConfiguration?
    private var connectDeadlineTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var disconnectTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var isSceneActive = true
    private var lastSentGrid: TerminalGridSize?
    @ObservationIgnored private var metrics = TerminalLatencyMetrics()
    // When the current connection last said ready; nil while it is not up.
    private var readyAt: ContinuousClock.Instant?
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var resumePoint: TerminalResumePoint?
    private var shouldReconnect = false

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

    func connect(hostText: String, paneID: String, credential: String) {
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

    func terminalGridDidChange(_ grid: TerminalGridSize) {
        guard grid != latestGridSize else { return }
        latestGridSize = grid
        guard connectionState.canSubmitInput else {
            Self.logger.info("grid change \(grid.columns)x\(grid.rows) deferred: cannot submit input in \(String(describing: self.connectionState))")
            return
        }
        Self.logger.info("grid change \(grid.columns)x\(grid.rows) queued for send")
        outbound.send(.resize(columns: grid.columns, rows: grid.rows), generation: connectionGeneration)
    }

    func terminalRendererDidAttach() {
        guard connectionState.canSubmitInput, let latestGridSize else { return }
        outbound.send(.resize(columns: latestGridSize.columns, rows: latestGridSize.rows), generation: connectionGeneration)
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
        endSession(.takenOver)
    }

    #if DEBUG
        func renderDevelopmentOutput(_ value: String) {
            bridge.receiveRemoteOutput(Data(value.utf8))
        }
    #endif

    private func beginConnection() {
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
            lastSentGrid = nil
            resumePoint = stream.map { TerminalResumePoint(stream: $0, offset: offset) }
            readyAt = timing.now()
            let elapsed = metrics.connectionStartedAt.map { $0.milliseconds(to: timing.now()) } ?? 0
            Self.logger.info("ready: generation=\(self.connectionGeneration) attempt=\(self.reconnectAttempt) resumed=\(resumed) afterMs=\(Int(elapsed))")
            transition(.ready)
            if let grid = latestGridSize {
                outbound.send(.resize(columns: grid.columns, rows: grid.rows), generation: connectionGeneration)
            }
            heartbeat.start(generation: connectionGeneration)
        case let .output(text):
            metrics.outputArrived(at: timing.now())
            bridge.receiveRemoteOutput(Data(text.utf8))
        case let .outputChunk(offset, data):
            metrics.outputArrived(at: timing.now())
            // The offset the host may trim behind moves only for bytes a live
            // surface has queued; the bridge answers synchronously (#108).
            if bridge.receiveRemoteOutput(data) {
                resumePoint?.advance(to: offset + UInt64(data.count))
            }
        case let .pong(identifier):
            heartbeat.pongReceived(identifier)
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
            // Whatever that surface accepted went with it; nil means a fresh attach.
            resumePoint = nil
            pauseSession()
        case .outputDiscarded:
            resumePoint = nil
            Self.logger.info("output discarded; the resume epoch is over")
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

    private func connectionEndedUnexpectedly(_ reason: TerminalRecoveryReason) {
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

    private func handlePath(_ event: NetworkPathWatch.Event) {
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
            if connectionState == .connected { askTheHeartbeat() } else { beginConnection() }
        case let .changed(from, to):
            logPath(from: from, to: to)
            // Only ask: an interface change is chatter, and a dial in
            // progress keeps its ready budget — restarting it on every
            // change never let a slow host finish (#107).
            if connectionState == .connected { askTheHeartbeat() }
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
    private func askTheHeartbeat() {
        heartbeat.start(generation: connectionGeneration, immediately: true)
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
            lastSentGrid = TerminalGridSize(columns: columns, rows: rows)
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

    private func transition(_ action: TerminalConnectionAction) {
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
        lastSentGrid = nil
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

    // The host's grid must converge on the latest rendered grid even when a
    // resize send is lost or deferred: checked after the outbound queue
    // drains and on every heartbeat.
    private func reconcileGridIfNeeded() {
        guard connectionState.canSubmitInput,
              outbound.isIdle,
              let latestGridSize,
              latestGridSize != lastSentGrid else { return }
        Self.logger.info("reconciling grid to \(latestGridSize.columns)x\(latestGridSize.rows)")
        outbound.send(.resize(columns: latestGridSize.columns, rows: latestGridSize.rows), generation: connectionGeneration)
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
