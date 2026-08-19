import Foundation
import Observation

@MainActor
@Observable
final class TerminalSessionController {
    private(set) var connectionState: TerminalConnectionState = .idle
    private(set) var errorMessage: String?
    private(set) var firstPaintMilliseconds: Double?
    private(set) var inputToOutputMilliseconds: Double?
    private(set) var latestGridSize: TerminalGridSize?

    let bridge = TerminalIOBridge()

    private let client: any TerminalTransporting
    private let clock = ContinuousClock()
    private let heartbeatPolicy: HeartbeatPolicy
    private let inputDelivery: TerminalInputDelivery
    private let reconnectPolicy: ReconnectPolicy
    private let timing: TerminalTiming

    private var configuration: TerminalConnectionConfiguration?
    private var connectionGeneration = 0
    private var connectionStartedAt: ContinuousClock.Instant?
    private var disconnectTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var heartbeatDeadlineTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var inputSentAt: ContinuousClock.Instant?
    private var outboundTaskID: UUID?
    private var outboundTask: Task<Void, Never>?
    private var outstandingHeartbeatID: String?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var shouldReconnect = false

    init(
        client: any TerminalTransporting = TerminalWebSocketClient(),
        reconnectPolicy: ReconnectPolicy = .terminalDefault,
        heartbeatPolicy: HeartbeatPolicy = .terminalDefault,
        timing: TerminalTiming = .live
    ) {
        self.client = client
        self.heartbeatPolicy = heartbeatPolicy
        inputDelivery = TerminalInputDelivery(sender: client)
        self.reconnectPolicy = reconnectPolicy
        self.timing = timing
        bridge.installInputConsumer { [weak self] data in
            self?.deliverTerminalInput(data)
        }
    }

    func connect(hostText: String, sessionText: String, credential: String) {
        do {
            guard let url = URL(string: hostText) else {
                throw HostEndpointError.invalidURL
            }
            let host = try HostEndpoint(baseURL: url)
            let sessionID = try SessionIdentifier(rawValue: sessionText)
            let configuration = try TerminalConnectionConfiguration(
                host: host,
                sessionID: sessionID,
                credential: credential
            )
            self.configuration = configuration
            errorMessage = nil
            shouldReconnect = true
            reconnectAttempt = 0
            firstPaintMilliseconds = nil
            inputToOutputMilliseconds = nil
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

    func submit(text: String) {
        guard connectionState.canSubmitInput else {
            errorMessage = "Wait for the terminal to reconnect before sending input."
            return
        }
        guard !text.isEmpty else { return }

        let payload: String
        if text.contains("\n") {
            payload = "\u{1B}[200~\(text)\u{1B}[201~\r"
        } else {
            payload = text + "\r"
        }
        deliverTerminalInput(Data(payload.utf8))
    }

    func sendQuickKey(_ key: TerminalQuickKey) {
        guard connectionState.canSubmitInput else { return }
        deliverTerminalInput(Data(key.sequence.utf8))
    }

    func terminalGridDidChange(_ grid: TerminalGridSize) {
        guard grid != latestGridSize else { return }
        latestGridSize = grid
        guard connectionState.canSubmitInput else { return }
        sendOnce(.resize(columns: grid.columns, rows: grid.rows))
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

        eventTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let pendingDisconnect {
                    await pendingDisconnect.value
                }
                guard isCurrentConnection(generation) else { return }
                await client.disconnect()
                guard isCurrentConnection(generation) else { return }
                try await client.connect(configuration: configuration)
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
        case .ready:
            reconnectAttempt = 0
            errorMessage = nil
            outstandingHeartbeatID = nil
            transition(.ready)
            if let grid = latestGridSize {
                sendOnce(.resize(columns: grid.columns, rows: grid.rows))
            }
            startHeartbeat()
        case let .output(text):
            if firstPaintMilliseconds == nil, let connectionStartedAt {
                firstPaintMilliseconds = milliseconds(from: connectionStartedAt, to: clock.now)
            }
            if let inputSentAt {
                inputToOutputMilliseconds = milliseconds(from: inputSentAt, to: clock.now)
                self.inputSentAt = nil
            }
            bridge.receiveRemoteOutput(Data(text.utf8))
        case let .pong(identifier):
            if outstandingHeartbeatID == identifier {
                outstandingHeartbeatID = nil
            }
        case .exit:
            shouldReconnect = false
            configuration = nil
            invalidateConnectionTasks()
            scheduleDisconnect()
            transition(.terminalExited)
        case let .error(message):
            errorMessage = message
        }
    }

    private func deliverTerminalInput(_ data: Data) {
        guard connectionState.canSubmitInput else { return }
        let value = String(decoding: data, as: UTF8.self)
        inputSentAt = clock.now
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

        heartbeatTask?.cancel()
        heartbeatDeadlineTask?.cancel()
        reconnectAttempt += 1
        transition(.connectionLost(nextAttempt: reconnectAttempt))
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
        reconnectTask = nil
        inputSentAt = nil
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
    }

    private func failPermanently(_ error: TerminalTransportError) {
        shouldReconnect = false
        configuration = nil
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

enum TerminalQuickKey: String, CaseIterable, Identifiable, Sendable {
    case escape = "Esc"
    case tab = "Tab"
    case interrupt = "Ctrl-C"
    case up = "↑"
    case down = "↓"

    var id: Self { self }

    var sequence: String {
        switch self {
        case .escape: "\u{1B}"
        case .tab: "\t"
        case .interrupt: "\u{03}"
        case .up: "\u{1B}[A"
        case .down: "\u{1B}[B"
        }
    }
}
