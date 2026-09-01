import Foundation
import Observation
import os

@MainActor
@Observable
final class TerminalSessionController {
    private static let logger = Logger(subsystem: "com.farfield.tavi", category: "terminal.connection")
    private static let maximumCoalescedInputBytes = 4 * 1_024
    private static let maximumPendingInputBytes = 64 * 1_024

    private(set) var connectionState: TerminalConnectionState = .idle
    private(set) var errorMessage: String?
    @ObservationIgnored private(set) var firstPaintMilliseconds: Double?
    @ObservationIgnored private(set) var inputToOutputMilliseconds: Double?
    private(set) var latestGridSize: TerminalGridSize?

    let bridge = TerminalIOBridge()

    private let client: any TerminalTransporting
    private let clock = ContinuousClock()
    private let heartbeatPolicy: HeartbeatPolicy
    private let inputDelivery: TerminalInputDelivery
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
    private var outboundTaskID: UUID?
    private var outboundTask: Task<Void, Never>?
    private var pendingInputChunks: [PendingTerminalInput] = []
    private var pendingInputByteCount = 0
    private var outstandingHeartbeatID: String?
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
        inputDelivery = TerminalInputDelivery(sender: client)
        self.pathObserver = pathObserver
        self.reconnectPolicy = reconnectPolicy
        self.timing = timing
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
    private(set) var controlLatchActive = false

    func toggleControlLatch() {
        controlLatchActive.toggle()
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

    func terminalGridDidChange(_ grid: TerminalGridSize) {
        guard grid != latestGridSize else { return }
        latestGridSize = grid
        guard connectionState.canSubmitInput else {
            Self.logger.info("grid change \(grid.columns)x\(grid.rows) deferred: cannot submit input in \(String(describing: self.connectionState))")
            return
        }
        Self.logger.info("grid change \(grid.columns)x\(grid.rows) queued for send")
        sendOnce(.resize(columns: grid.columns, rows: grid.rows))
    }

    func terminalRendererDidAttach() {
        guard connectionState.canSubmitInput, let latestGridSize else { return }
        sendOnce(.resize(columns: latestGridSize.columns, rows: latestGridSize.rows))
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
        outboundTask?.cancel()
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
                sendOnce(.resize(columns: grid.columns, rows: grid.rows))
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

    private func deliverTerminalInput(_ data: Data, canCoalesce: Bool = true) {
        guard connectionState.canSubmitInput else { return }
        guard !data.isEmpty else { return }
        var data = data
        if controlLatchActive {
            // One-shot Ctrl modifier from the quick row: the next single
            // keystroke becomes its control code; anything unmappable
            // passes through and still releases the latch.
            controlLatchActive = false
            if let controlCode = TerminalControlKeyMapper.controlCode(for: data) {
                data = controlCode
            }
        }
        if data.first == 0x1B {
            Self.logger.info("terminal-originated control sequence, \(data.count) bytes")
        }
        inputSentAt = clock.now

        guard outboundTask == nil, pendingInputChunks.isEmpty else {
            enqueuePendingInput(data, canCoalesce: canCoalesce)
            return
        }
        sendInput(data)
    }

    private func enqueuePendingInput(_ data: Data, canCoalesce: Bool) {
        guard pendingInputByteCount <= Self.maximumPendingInputBytes - data.count else {
            errorMessage = "Terminal input is backed up. Wait for the connection to catch up."
            return
        }

        if canCoalesce,
           let lastIndex = pendingInputChunks.indices.last,
           pendingInputChunks[lastIndex].canCoalesce,
           pendingInputChunks[lastIndex].data.count <= Self.maximumCoalescedInputBytes - data.count {
            pendingInputChunks[lastIndex].data.append(data)
        } else {
            pendingInputChunks.append(PendingTerminalInput(data: data, canCoalesce: canCoalesce))
        }
        pendingInputByteCount += data.count
    }

    private func sendInput(_ data: Data) {
        let value = String(decoding: data, as: UTF8.self)
        sendOnce(.input(value), inputWasSubmitted: true)
    }

    @discardableResult
    private func sendOnce(
        _ message: TerminalClientMessage,
        inputWasSubmitted: Bool = false
    ) -> Task<Void, Never> {
        let previousTask = outboundTask
        let generation = connectionGeneration
        let taskID = UUID()
        outboundTaskID = taskID
        let task = Task { [weak self] in
            if let previousTask {
                await previousTask.value
            }
            guard let self, isCurrentConnection(generation) else { return }
            defer { finishOutboundTask(taskID) }
            do {
                if case let .input(data) = message {
                    try await inputDelivery.submitOnce(Data(data.utf8))
                } else {
                    try await client.send(message)
                    if case let .resize(columns, rows) = message {
                        lastSentGrid = TerminalGridSize(columns: columns, rows: rows)
                        Self.logger.info("resize \(columns)x\(rows) sent to host")
                    }
                }
            } catch let error as TerminalTransportError {
                guard isCurrentConnection(generation) else { return }
                if error == .oversizedFrame {
                    errorMessage = error.localizedDescription
                    inputSentAt = nil
                    return
                }
                if inputWasSubmitted {
                    errorMessage = error == .deliveryUncertain
                        ? error.localizedDescription
                        : "Input was not sent."
                    inputSentAt = nil
                }
                connectionEndedUnexpectedly()
            } catch {
                guard isCurrentConnection(generation) else { return }
                if inputWasSubmitted {
                    errorMessage = TerminalTransportError.deliveryUncertain.localizedDescription
                    inputSentAt = nil
                }
                connectionEndedUnexpectedly()
            }
        }
        outboundTask = task
        return task
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
            firstPaintMilliseconds = milliseconds(from: connectionStartedAt, to: clock.now)
        }
        if let inputSentAt {
            inputToOutputMilliseconds = milliseconds(from: inputSentAt, to: clock.now)
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
            "network path restored or changed (\(previous.interfaceIdentity) -> \(snapshot.interfaceIdentity)); reconnecting now"
        )
        // A socket opened on the previous path is dead or stale even when it
        // still looks connected, so cycle immediately instead of waiting for
        // a heartbeat timeout or a scheduled backoff retry.
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
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

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatDeadlineTask?.cancel()
        let generation = connectionGeneration
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    try await timing.sleep(heartbeatPolicy.interval)
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
                let sendTask = sendOnce(.ping(identifier: identifier))
                await sendTask.value
                guard isCurrentConnection(generation) else { return }
                reconcileGridIfNeeded()
                await deadlineTask.value
                guard isCurrentConnection(generation) else { return }
            }
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
        outboundTask?.cancel()
        reconnectTask?.cancel()
        eventTask = nil
        heartbeatDeadlineTask = nil
        heartbeatTask = nil
        outboundTask = nil
        outboundTaskID = nil
        pendingInputChunks.removeAll(keepingCapacity: false)
        pendingInputByteCount = 0
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

    private func finishOutboundTask(_ taskID: UUID) {
        guard outboundTaskID == taskID else { return }
        outboundTask = nil
        outboundTaskID = nil
        guard pendingInputChunks.isEmpty else {
            let pending = pendingInputChunks.removeFirst()
            pendingInputByteCount -= pending.data.count
            sendInput(pending.data)
            return
        }
        reconcileGridIfNeeded()
    }

    // The grid the host believes in must converge on the latest rendered
    // grid even when an individual resize send is lost, raced by a layout
    // transition, or deferred while reconnecting. Reconciliation runs after
    // the outbound queue drains and on every heartbeat.
    private func reconcileGridIfNeeded() {
        guard connectionState.canSubmitInput,
              outboundTask == nil,
              let latestGridSize,
              latestGridSize != lastSentGrid else { return }
        Self.logger.info("reconciling grid to \(latestGridSize.columns)x\(latestGridSize.rows)")
        sendOnce(.resize(columns: latestGridSize.columns, rows: latestGridSize.rows))
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

    private func milliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Double {
        let duration = start.duration(to: end)
        let components = duration.components
        let seconds = Double(components.seconds) * 1_000
        let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000
        return seconds + attoseconds
    }
}

private struct PendingTerminalInput {
    var data: Data
    let canCoalesce: Bool
}

enum TerminalQuickKey: String, CaseIterable, Identifiable, Sendable {
    case escape = "Esc"
    case tab = "Tab"
    case shiftTab = "⇧Tab"
    case enter = "Enter"
    case interrupt = "Ctrl-C"
    case left = "←"
    case up = "↑"
    case down = "↓"
    case right = "→"

    var id: Self { self }

    // The key row groups like a keyboard (#54): named keys and the
    // interrupt in one cluster, arrows in another.
    static let commandCluster: [TerminalQuickKey] = [.escape, .tab, .shiftTab, .enter, .interrupt]
    static let arrowCluster: [TerminalQuickKey] = [.left, .up, .down, .right]

    // One key language on the caps: lowercase words, matching the "ctrl"
    // latch beside them ("⌃C" next to a spelled-out ctrl was the audit's
    // exact complaint in new notation; "⏎" appears on no iOS keyboard).
    // Arrows stay arrows — they are their own word.
    var face: String {
        switch self {
        case .escape: "esc"
        case .tab: "tab"
        case .shiftTab: "⇧tab"
        case .enter: "enter"
        case .interrupt: "ctrl-c"
        case .left: "←"
        case .up: "↑"
        case .down: "↓"
        case .right: "→"
        }
    }

    var sequence: String {
        switch self {
        case .escape: "\u{1B}"
        case .tab: "\t"
        case .shiftTab: "\u{1B}[Z"
        case .enter: "\r"
        case .interrupt: "\u{03}"
        case .left: "\u{1B}[D"
        case .up: "\u{1B}[A"
        case .down: "\u{1B}[B"
        case .right: "\u{1B}[C"
        }
    }
}

// Maps a single typed character to its control code (Ctrl-A ... Ctrl-_)
// for the quick-row Ctrl latch. Anything that has no control counterpart
// returns nil and the keystroke passes through unmodified.
enum TerminalControlKeyMapper {
    static func controlCode(for data: Data) -> Data? {
        guard data.count == 1, var byte = data.first else { return nil }
        if (0x61...0x7A).contains(byte) { byte -= 0x20 }
        guard (0x40...0x5F).contains(byte) else { return nil }
        return Data([byte & 0x1F])
    }
}
