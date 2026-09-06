import Foundation
import Observation
import os

@MainActor
@Observable
final class TerminalSessionController {
    private static let logger = Logger(subsystem: "com.farfield.tavi", category: "terminal.connection")

    private(set) var connectionState: TerminalConnectionState = .idle
    private(set) var errorMessage: String?
    @ObservationIgnored private(set) var firstPaintMilliseconds: Double?
    @ObservationIgnored private(set) var inputToOutputMilliseconds: Double?
    private(set) var latestGridSize: TerminalGridSize?
    // One deliberate attach, which Jump-to can point at a different pane
    // while the same screen stays on top. The terminal view keys the
    // renderer to it, so a new pane gets a clean surface; an ordinary
    // reconnect leaves it alone and keeps the one on screen (#108).
    private(set) var sessionID = 0
    // What is on and recently above the screen, as plain text — the
    // renderer's accessibility transcript. Read by "Files mentioned" (#61)
    // when the sheet opens; nothing is derived from it eagerly.
    // Unobserved on purpose: it republishes 4×/s and would invalidate the
    // whole terminal screen every time (#68 phone 1).
    @ObservationIgnored private(set) var latestTranscript = ""
    // Localhost ports the transcript names, for the Preview button (#58).
    var mentionedPorts: [Int] { mentioned.ports }

    let bridge = TerminalIOBridge()

    private let client: any TerminalTransporting
    private let reconnectPolicy: ReconnectPolicy
    // Not private: the heartbeat lives in TerminalSessionHeartbeat.swift,
    // which is the only other reader, and Swift has no narrower scope than
    // the module for that.
    let heartbeatPolicy: HeartbeatPolicy
    let outbound: TerminalOutbound
    let timing: TerminalTiming
    // Answer bound and send bound are separate handles under separate
    // tokens: a pong proves the host replied, not that our send returned.
    var heartbeatDeadlineTask: Task<Void, Never>?
    var heartbeatSendBound: Task<Void, Never>?
    var heartbeatTask: Task<Void, Never>?
    var outstandingHeartbeatID: String?
    var outstandingHeartbeatSendID: String?

    private var connectDeadlineTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var connectionStartedAt: ContinuousClock.Instant?
    private var disconnectTask: Task<Void, Never>?
    private var lastPathSnapshot: NetworkPathSnapshot?
    private var pathTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var inputSentAt: ContinuousClock.Instant?
    private var lastSentGrid: TerminalGridSize?
    private let mentioned = MentionedPorts()
    private var reconnectTask: Task<Void, Never>?
    // When the current connection last said ready; nil while it is not up.
    private var readyAt: ContinuousClock.Instant?

    // Not private: the attachment lives in TerminalSessionAttachment.swift,
    // which owns the resume point and decides when this session may be live
    // at all. Swift has no scope between private and the module for that.
    var configuration: TerminalConnectionConfiguration?
    var isSceneActive = true
    var reconnectAttempt = 0
    var resumePoint: TerminalResumePoint?
    var shouldReconnect = false

    private let pathObserver: any NetworkPathObserving

    init(
        client: any TerminalTransporting = TerminalWebSocketClient(),
        reconnectPolicy: ReconnectPolicy = .terminalDefault,
        heartbeatPolicy: HeartbeatPolicy = .terminalDefault,
        timing: TerminalTiming = .live,
        pathObserver: any NetworkPathObserving = NetworkPathObserver()
    ) {
        self.client = client
        self.heartbeatPolicy = heartbeatPolicy
        outbound = TerminalOutbound(client: client)
        self.pathObserver = pathObserver
        self.reconnectPolicy = reconnectPolicy
        self.timing = timing
        outbound.installGenerationCheck { [weak self] generation in
            self?.isCurrentConnection(generation) ?? false
        }
        outbound.installOutcomeConsumer { [weak self] outcome in
            self?.handle(outcome)
        }
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
            firstPaintMilliseconds = nil
            inputToOutputMilliseconds = nil
            sessionID += 1
            // The replacement surface publishes nothing until it has drawn,
            // so without this Files mentioned and the Preview button would
            // answer for the previous pane all through the new pane's
            // connecting window (#108).
            latestTranscript = ""
            mentioned.clear()
            bridge.beginSession(sessionID)
            startPathMonitoringIfNeeded()
            beginConnection()
        } catch {
            errorMessage = error.localizedDescription
            if configuration == nil {
                transition(.unrecoverableFailure)
            }
        }
    }

    func stop() {
        pathTask?.cancel()
        pathTask = nil
        mentioned.clear()
        lastPathSnapshot = nil
        endSession(.stop)
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

    #if DEBUG
        func renderDevelopmentOutput(_ value: String) {
            bridge.receiveRemoteOutput(Data(value.utf8))
        }
    #endif

    func beginConnection() {
        guard shouldReconnect, let configuration else { return }
        eventTask?.cancel()
        heartbeatTask?.cancel()
        clearHeartbeatBounds()
        readyAt = nil
        outbound.cancel()
        // Cancelled *and* released: a retained handle held the retry gate in
        // connectionEndedUnexpectedly() shut forever, and the terminal stayed
        // on Connecting (#107).
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionGeneration += 1
        let generation = connectionGeneration
        let pendingDisconnect = disconnectTask
        transition(.connect)
        connectionStartedAt = timing.now()
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
            // A ready that lands after the deadline fired, while the retry
            // is still waiting out its delay, is a success and not a
            // straggler: letting the scheduled dial run would tear down a
            // socket that just proved itself (#107).
            reconnectTask?.cancel()
            reconnectTask = nil
            errorMessage = nil
            lastSentGrid = nil
            resumePoint = stream.map { TerminalResumePoint(stream: $0, offset: offset) }
            readyAt = timing.now()
            let elapsed = connectionStartedAt.map { $0.milliseconds(to: timing.now()) } ?? 0
            Self.logger.info("ready: generation=\(self.connectionGeneration) attempt=\(self.reconnectAttempt) resumed=\(resumed) afterMs=\(Int(elapsed))")
            transition(.ready)
            if let grid = latestGridSize {
                outbound.send(.resize(columns: grid.columns, rows: grid.rows), generation: connectionGeneration)
            }
            startHeartbeat(generation: connectionGeneration)
        case let .output(text):
            recordOutputTimings()
            bridge.receiveRemoteOutput(Data(text.utf8))
        case let .outputChunk(offset, data):
            recordOutputTimings()
            acceptOutput(offset: offset, data: data)
        case let .pong(identifier):
            if outstandingHeartbeatID == identifier {
                outstandingHeartbeatID = nil
                // Release the answer bound only: sitting its budget out made
                // a healthy cadence interval + timeout, and a reply says
                // nothing about our own queue draining.
                heartbeatDeadlineTask?.cancel()
                heartbeatDeadlineTask = nil
            }
        case .exit:
            endSession(.terminalExited)
        case let .error(message, _):
            errorMessage = message
        }
    }

    func connectionEndedUnexpectedly(_ reason: TerminalRecoveryReason) {
        guard shouldReconnect, connectionState != .suspended, connectionState != .ended else {
            return
        }
        // A trigger dropped because a dial is already scheduled is exactly
        // what #107 is about; it leaves a trace rather than vanishing.
        guard reconnectTask == nil else {
            Self.logger.info("cycle ignored, retry pending: reason=\(reason.rawValue, privacy: .public) generation=\(self.connectionGeneration)")
            return
        }

        connectDeadlineTask?.cancel()
        connectDeadlineTask = nil
        heartbeatTask?.cancel()
        clearHeartbeatBounds()
        // The backoff forgets the attempts behind it only once a connection
        // has held for the documented period, so repeated flaps cannot walk
        // the delay back to its shortest value (#107) — the events stream's
        // rule.
        if let readyAt, readyAt.duration(to: timing.now()) >= reconnectPolicy.sustainedHealthInterval {
            reconnectAttempt = 0
        }
        readyAt = nil
        reconnectAttempt += 1
        if lastPathSnapshot?.isSatisfied == false {
            transition(.networkLost)
        } else {
            transition(.connectionLost(nextAttempt: reconnectAttempt))
        }
        let delay = reconnectPolicy.delay(forAttempt: reconnectAttempt)
        let generation = connectionGeneration
        let timing = timing
        // The reason is public on purpose: Logger redacts dynamic strings by
        // default, and this closed enum of fixed tokens is the one field the
        // record exists to carry.
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
            // Straight into the dial, with no await in between: the
            // generation bump inside beginConnection() happens synchronously
            // here, so the intentional close the old receive loop would
            // otherwise report as a failure is discarded (#107).
            reconnectTask = nil
            beginConnection()
        }
    }

    private func recordOutputTimings() {
        if firstPaintMilliseconds == nil, let connectionStartedAt {
            firstPaintMilliseconds = connectionStartedAt.milliseconds(to: timing.now())
        }
        if let inputSentAt {
            inputToOutputMilliseconds = inputSentAt.milliseconds(to: timing.now())
            self.inputSentAt = nil
        }
    }

    private func startPathMonitoringIfNeeded() {
        guard pathTask == nil else { return }
        let observer = pathObserver
        pathTask = Task { [weak self] in
            for await snapshot in observer.updates() {
                guard let self, !Task.isCancelled else { return }
                handlePathUpdate(snapshot)
            }
        }
    }

    private func handlePathUpdate(_ snapshot: NetworkPathSnapshot) {
        let previous = lastPathSnapshot
        lastPathSnapshot = snapshot
        guard configuration != nil, shouldReconnect, connectionState != .suspended else { return }
        guard previous != snapshot else { return }

        if !snapshot.isSatisfied {
            Self.logger.info("network path lost: generation=\(self.connectionGeneration)")
            transition(.networkLost)
            // Keep the retry loop alive so recovery never depends on the
            // monitor delivering a satisfied event later.
            connectionEndedUnexpectedly(.networkPathLost)
            return
        }

        // The first snapshot only records the baseline; churning a healthy
        // startup connection would add latency for nothing.
        guard let previous else { return }
        Self.logger.info(
            "network path restored or changed (\(previous.interfaceIdentity) -> \(snapshot.interfaceIdentity))"
        )
        // A socket is judged by its own heartbeat (#86, PRD §7.13): on
        // cellular the interface list changes at every handover and most
        // of those leave a working socket working. Ask it now; the 5 s
        // heartbeat timeout decides. A dial still in progress is cycled,
        // since its packets may be on the old path — without resetting
        // the backoff, so a flapping path cannot defeat it.
        if connectionState == .connected {
            startHeartbeat(generation: connectionGeneration, immediately: true)
            return
        }
        // A network that comes back after being lost is a real signal, not
        // a flap: dial now rather than waiting out the scheduled retry —
        // the attempt count stays, so the next failure backs off further.
        // beginConnection() releases the scheduled retry itself.
        if !previous.isSatisfied {
            beginConnection()
            return
        }
        // Satisfied to satisfied is chatter, and a dial in progress owns its
        // ready budget: restarting it handed it a fresh deadline on every
        // interface change, so a flapping route never let a host finish.
        guard connectionState != .connecting, reconnectTask == nil else { return }
        beginConnection()
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

    // Either heartbeat bound expiring says the same thing to the person:
    // the host is not answering. Which bound it was stays in the log.
    func heartbeatDidTimeOut(_ reason: TerminalRecoveryReason) {
        errorMessage = "The host stopped responding. Reconnecting."
        connectionEndedUnexpectedly(reason)
    }

    private func deliverTerminalInput(_ data: Data, canCoalesce: Bool = true) {
        guard connectionState.canSubmitInput, !data.isEmpty else { return }
        inputSentAt = timing.now()
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
                inputSentAt = nil
                return
            }
            if inputWasSubmitted {
                // An unnamed transport failure is as uncertain as delivery
                // gets: never say the input was not sent when it may have been.
                errorMessage = error == nil || error == .deliveryUncertain
                    ? TerminalTransportError.deliveryUncertain.localizedDescription
                    : "Input was not sent."
                inputSentAt = nil
            }
            connectionEndedUnexpectedly(.outboundFailed)
        case .drained:
            reconcileGridIfNeeded()
        case .backedUp:
            errorMessage = "Terminal input is backed up. Wait for the connection to catch up."
        }
    }

    func transition(_ action: TerminalConnectionAction) {
        connectionState = TerminalConnectionReducer.reduce(connectionState, action: action)
    }

    func invalidateConnectionTasks() {
        connectionGeneration += 1
        connectDeadlineTask?.cancel()
        connectDeadlineTask = nil
        eventTask?.cancel()
        heartbeatTask?.cancel()
        clearHeartbeatBounds()
        outbound.cancel()
        reconnectTask?.cancel()
        eventTask = nil
        heartbeatTask = nil
        reconnectTask = nil
        readyAt = nil
        inputSentAt = nil
        lastSentGrid = nil
    }

    // Both bounds and the tokens they answer to, released together: neither
    // may outlive the round that armed it.
    func clearHeartbeatBounds() {
        heartbeatDeadlineTask?.cancel()
        heartbeatDeadlineTask = nil
        heartbeatSendBound?.cancel()
        heartbeatSendBound = nil
        outstandingHeartbeatID = nil
        outstandingHeartbeatSendID = nil
    }

    func isCurrentConnection(_ generation: Int) -> Bool {
        generation == connectionGeneration && !Task.isCancelled
    }

    func scheduleDisconnect() {
        guard disconnectTask == nil else { return }
        let client = client
        disconnectTask = Task { [weak self] in
            await client.disconnect()
            self?.disconnectTask = nil
        }
    }

    // The grid the host believes in must converge on the latest rendered
    // grid even when an individual resize send is lost, raced by a layout
    // transition, or deferred while reconnecting. Reconciliation runs after
    // the outbound queue drains and on every heartbeat.
    func reconcileGridIfNeeded() {
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
    func endSession(_ action: TerminalConnectionAction) {
        shouldReconnect = false
        configuration = nil
        resumePoint = nil
        // The surface on screen keeps what it has drawn, but bytes still
        // waiting for a surface belong to a stream nobody can resume.
        bridge.discardPendingOutput()
        invalidateConnectionTasks()
        scheduleDisconnect()
        transition(action)
    }
}
