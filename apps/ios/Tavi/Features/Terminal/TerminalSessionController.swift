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
    private let clock = ContinuousClock()
    private let heartbeatPolicy: HeartbeatPolicy
    private let outbound: TerminalOutbound
    private let reconnectPolicy: ReconnectPolicy
    private let timing: TerminalTiming

    private var configuration: TerminalConnectionConfiguration?
    private var connectDeadlineTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var connectionStartedAt: ContinuousClock.Instant?
    private var disconnectTask: Task<Void, Never>?
    private var lastPathSnapshot: NetworkPathSnapshot?
    private var pathTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var heartbeatDeadlineTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var inputSentAt: ContinuousClock.Instant?
    private var lastSentGrid: TerminalGridSize?
    private var outstandingHeartbeatID: String?
    private let mentioned = MentionedPorts()
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var resumeOffset: UInt64 = 0
    private var resumeStream: String?
    private var shouldReconnect = false

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
            resumeStream = nil
            resumeOffset = 0
            firstPaintMilliseconds = nil
            inputToOutputMilliseconds = nil
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
        shouldReconnect = false
        configuration = nil
        resumeStream = nil
        resumeOffset = 0
        pathTask?.cancel()
        pathTask = nil
        mentioned.clear()
        lastPathSnapshot = nil
        invalidateConnectionTasks()
        scheduleDisconnect()
        transition(.stop)
    }

    func sceneDidBecomeActive() {
        guard connectionState == .suspended, configuration != nil else { return }
        shouldReconnect = true
        reconnectAttempt = 0
        transition(.resume)
        beginConnection()
    }

    func sceneWillResignActive() {
        guard configuration != nil else { return }
        shouldReconnect = false
        invalidateConnectionTasks()
        scheduleDisconnect()
        transition(.suspend)
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
        shouldReconnect = false
        configuration = nil
        invalidateConnectionTasks()
        scheduleDisconnect()
        transition(.unrecoverableFailure)
    }

    #if DEBUG
        func renderDevelopmentOutput(_ value: String) {
            bridge.receiveRemoteOutput(Data(value.utf8))
        }
    #endif

    private func beginConnection() {
        guard shouldReconnect, let configuration else { return }
        eventTask?.cancel()
        heartbeatTask?.cancel()
        heartbeatDeadlineTask?.cancel()
        outbound.cancel()
        reconnectTask?.cancel()
        connectionGeneration += 1
        let generation = connectionGeneration
        let pendingDisconnect = disconnectTask
        transition(.connect)
        connectionStartedAt = clock.now
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
                try await client.connect(configuration: configuration, resume: currentResumePoint())
                while isCurrentConnection(generation) {
                    let event = await client.receive()
                    guard isCurrentConnection(generation) else { return }
                    handle(event)
                    switch event {
                    case .message:
                        continue
                    case .disconnected, .failed:
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
                    connectionEndedUnexpectedly()
                }
            } catch {
                guard isCurrentConnection(generation) else { return }
                connectionEndedUnexpectedly()
            }
        }
    }

    private func handle(_ event: TerminalTransportEvent) {
        switch event {
        case let .message(message):
            handle(message)
        case .disconnected:
            connectionEndedUnexpectedly()
        case let .failed(error):
            if error.isPermanentConnectionFailure {
                failPermanently(error)
            } else {
                connectionEndedUnexpectedly()
            }
        }
    }

    private func handle(_ message: TerminalServerMessage) {
        switch message {
        case let .ready(stream, offset, resumed):
            connectDeadlineTask?.cancel()
            connectDeadlineTask = nil
            reconnectAttempt = 0
            errorMessage = nil
            outstandingHeartbeatID = nil
            lastSentGrid = nil
            resumeStream = stream
            resumeOffset = offset
            Self.logger.info("ready: resumed=\(resumed) offset=\(offset)")
            transition(.ready)
            if let grid = latestGridSize {
                outbound.send(.resize(columns: grid.columns, rows: grid.rows), generation: connectionGeneration)
            }
            startHeartbeat()
        case let .output(text):
            recordOutputTimings()
            bridge.receiveRemoteOutput(Data(text.utf8))
        case let .outputChunk(offset, data):
            recordOutputTimings()
            resumeOffset = offset + UInt64(data.count)
            bridge.receiveRemoteOutput(data)
        case let .pong(identifier):
            if outstandingHeartbeatID == identifier {
                outstandingHeartbeatID = nil
            }
        case .exit:
            shouldReconnect = false
            configuration = nil
            resumeStream = nil
            resumeOffset = 0
            invalidateConnectionTasks()
            scheduleDisconnect()
            transition(.terminalExited)
        case let .error(message):
            errorMessage = message
        }
    }

    private func connectionEndedUnexpectedly() {
        guard shouldReconnect, connectionState != .suspended, connectionState != .ended else {
            return
        }
        guard reconnectTask == nil else { return }

        connectDeadlineTask?.cancel()
        connectDeadlineTask = nil
        heartbeatTask?.cancel()
        heartbeatDeadlineTask?.cancel()
        reconnectAttempt += 1
        if lastPathSnapshot?.isSatisfied == false {
            transition(.networkLost)
        } else {
            transition(.connectionLost(nextAttempt: reconnectAttempt))
        }
        let delay = reconnectPolicy.delay(forAttempt: reconnectAttempt)
        let generation = connectionGeneration
        let timing = timing
        reconnectTask = Task { [weak self] in
            do {
                try await timing.sleep(delay)
            } catch {
                return
            }
            guard let self, shouldReconnect, isCurrentConnection(generation) else { return }
            reconnectTask = nil
            await client.disconnect()
            guard isCurrentConnection(generation) else { return }
            beginConnection()
        }
    }

    private func currentResumePoint() -> TerminalResumePoint? {
        guard let resumeStream else { return nil }
        return TerminalResumePoint(stream: resumeStream, offset: resumeOffset)
    }

    private func recordOutputTimings() {
        if firstPaintMilliseconds == nil, let connectionStartedAt {
            firstPaintMilliseconds = connectionStartedAt.milliseconds(to: clock.now)
        }
        if let inputSentAt {
            inputToOutputMilliseconds = inputSentAt.milliseconds(to: clock.now)
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
            Self.logger.info("network path lost")
            transition(.networkLost)
            // Keep the retry loop alive so recovery never depends on the
            // monitor delivering a satisfied event later.
            connectionEndedUnexpectedly()
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
            startHeartbeat(immediately: true)
            return
        }
        // A network that comes back after being lost is a real signal, not
        // a flap: dial now rather than waiting out the scheduled retry —
        // the attempt count stays, so the next failure backs off further.
        if !previous.isSatisfied {
            reconnectTask?.cancel()
            reconnectTask = nil
            beginConnection()
            return
        }
        guard reconnectTask == nil else { return }
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
            Self.logger.info("connect attempt exceeded deadline; cycling")
            connectionEndedUnexpectedly()
        }
    }

    private func startHeartbeat(immediately: Bool = false) {
        heartbeatTask?.cancel()
        heartbeatDeadlineTask?.cancel()
        let generation = connectionGeneration
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

                let identifier = UUID().uuidString
                outstandingHeartbeatID = identifier
                let deadlineTask = Task { @MainActor [weak self] in
                    do {
                        guard let self else { return }
                        try await timing.sleep(heartbeatPolicy.timeout)
                    } catch {
                        return
                    }
                    guard let self,
                          isCurrentConnection(generation),
                          outstandingHeartbeatID == identifier else { return }
                    errorMessage = "The host stopped responding. Reconnecting."
                    connectionEndedUnexpectedly()
                }
                heartbeatDeadlineTask = deadlineTask
                let sendTask = outbound.send(.ping(identifier: identifier), generation: connectionGeneration)
                await sendTask.value
                guard isCurrentConnection(generation) else { return }
                reconcileGridIfNeeded()
                await deadlineTask.value
                guard isCurrentConnection(generation) else { return }
            }
        }
    }

    private func deliverTerminalInput(_ data: Data, canCoalesce: Bool = true) {
        guard connectionState.canSubmitInput, !data.isEmpty else { return }
        inputSentAt = clock.now
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
            connectionEndedUnexpectedly()
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
        heartbeatDeadlineTask?.cancel()
        heartbeatTask?.cancel()
        outbound.cancel()
        reconnectTask?.cancel()
        eventTask = nil
        heartbeatDeadlineTask = nil
        heartbeatTask = nil
        reconnectTask = nil
        inputSentAt = nil
        lastSentGrid = nil
        outstandingHeartbeatID = nil
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

    // The grid the host believes in must converge on the latest rendered
    // grid even when an individual resize send is lost, raced by a layout
    // transition, or deferred while reconnecting. Reconciliation runs after
    // the outbound queue drains and on every heartbeat.
    private func reconcileGridIfNeeded() {
        guard connectionState.canSubmitInput,
              outbound.isIdle,
              let latestGridSize,
              latestGridSize != lastSentGrid else { return }
        Self.logger.info("reconciling grid to \(latestGridSize.columns)x\(latestGridSize.rows)")
        outbound.send(.resize(columns: latestGridSize.columns, rows: latestGridSize.rows), generation: connectionGeneration)
    }

    private func failPermanently(_ error: TerminalTransportError) {
        shouldReconnect = false
        configuration = nil
        resumeStream = nil
        resumeOffset = 0
        errorMessage = error.localizedDescription
        invalidateConnectionTasks()
        scheduleDisconnect()
        transition(.unrecoverableFailure)
    }
}
