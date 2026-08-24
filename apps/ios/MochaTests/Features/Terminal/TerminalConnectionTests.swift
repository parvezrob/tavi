import Foundation
import Testing
@testable import Mocha

struct TerminalConnectionTests {
    @Test
    func reducerModelsConnectReconnectSuspendAndResume() {
        var state = TerminalConnectionState.idle
        state = TerminalConnectionReducer.reduce(state, action: .connect)
        #expect(state == .connecting)

        state = TerminalConnectionReducer.reduce(state, action: .ready)
        #expect(state == .connected)

        state = TerminalConnectionReducer.reduce(state, action: .connectionLost(nextAttempt: 2))
        #expect(state == .reconnecting(attempt: 2))

        state = TerminalConnectionReducer.reduce(state, action: .suspend)
        #expect(state == .suspended)

        state = TerminalConnectionReducer.reduce(state, action: .connectionLost(nextAttempt: 3))
        #expect(state == .suspended)

        state = TerminalConnectionReducer.reduce(state, action: .resume)
        #expect(state == .connecting)

        state = TerminalConnectionReducer.reduce(state, action: .terminalExited)
        #expect(TerminalConnectionReducer.reduce(state, action: .suspend) == .ended)
        #expect(TerminalConnectionReducer.reduce(.failed, action: .suspend) == .failed)
    }

    @Test
    func reducerModelsHonestNetworkLossStates() {
        #expect(TerminalConnectionReducer.reduce(.connected, action: .networkLost) == .waitingForNetwork)
        #expect(TerminalConnectionReducer.reduce(.connecting, action: .networkLost) == .waitingForNetwork)
        #expect(
            TerminalConnectionReducer.reduce(.reconnecting(attempt: 3), action: .networkLost)
                == .waitingForNetwork
        )
        #expect(TerminalConnectionReducer.reduce(.suspended, action: .networkLost) == .suspended)
        #expect(TerminalConnectionReducer.reduce(.failed, action: .networkLost) == .failed)
        #expect(
            TerminalConnectionReducer.reduce(.waitingForNetwork, action: .connectionLost(nextAttempt: 4))
                == .waitingForNetwork
        )
        #expect(TerminalConnectionReducer.reduce(.waitingForNetwork, action: .connect) == .connecting)
        #expect(TerminalConnectionReducer.reduce(.waitingForNetwork, action: .ready) == .connected)
    }

    @Test
    @MainActor
    func restoredNetworkPathReconnectsImmediatelyWithoutBackoff() async throws {
        let paths = ScriptedPathObserver()
        let transport = ScriptedTerminalTransport()
        let controller = TerminalSessionController(
            client: transport,
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .seconds(60),
                maximumDelay: .seconds(60),
                multiplier: 1,
                connectDeadline: .seconds(60)
            ),
            pathObserver: paths
        )

        controller.connect(
            hostText: "https://mac.tailnet.ts.net",
            sessionText: "fixture",
            credential: "valid-token"
        )
        try await transport.emit(.message(.ready))
        try await waitUntil { controller.connectionState == .connected }

        paths.emit(NetworkPathSnapshot(isSatisfied: false, interfaceIdentity: "none"))
        try await waitUntil { controller.connectionState == .waitingForNetwork }

        paths.emit(NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "en0"))
        try await waitUntil { await transport.connectCount >= 2 }
        try await transport.emit(.message(.ready))
        try await waitUntil { controller.connectionState == .connected }
        controller.stop()
    }

    @Test
    @MainActor
    func interfaceFlipWhileConnectedCyclesTheConnection() async throws {
        let paths = ScriptedPathObserver()
        let transport = ScriptedTerminalTransport()
        let controller = TerminalSessionController(
            client: transport,
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .seconds(60),
                maximumDelay: .seconds(60),
                multiplier: 1,
                connectDeadline: .seconds(60)
            ),
            pathObserver: paths
        )

        controller.connect(
            hostText: "https://mac.tailnet.ts.net",
            sessionText: "fixture",
            credential: "valid-token"
        )
        try await transport.emit(.message(.ready))
        try await waitUntil { controller.connectionState == .connected }

        paths.emit(NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "en0"))
        await yieldExecution()
        #expect(await transport.connectCount == 1)

        paths.emit(NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "pdp_ip0"))
        try await waitUntil { await transport.connectCount >= 2 }
        try await transport.emit(.message(.ready))
        try await waitUntil { controller.connectionState == .connected }
        controller.stop()
    }

    @Test
    @MainActor
    func stalledConnectAttemptIsCycledAtTheDeadline() async throws {
        let sleeper = ManualTerminalSleeper()
        let transport = ScriptedTerminalTransport()
        let controller = TerminalSessionController(
            client: transport,
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .seconds(60),
                maximumDelay: .seconds(60),
                multiplier: 1,
                connectDeadline: .seconds(3)
            ),
            timing: sleeper.timing
        )

        controller.connect(
            hostText: "https://mac.tailnet.ts.net",
            sessionText: "fixture",
            credential: "valid-token"
        )
        #expect(controller.connectionState == .connecting)
        try await waitUntil { await sleeper.hasWaiter(for: .seconds(3)) }
        try await sleeper.resumeFirst(for: .seconds(3))
        try await waitUntil {
            if case .reconnecting = controller.connectionState { return true }
            return false
        }
        controller.stop()
    }

    @Test
    func reconnectDelayGrowsAndCaps() {
        let policy = ReconnectPolicy(
            initialDelay: .milliseconds(250),
            maximumDelay: .seconds(2),
            multiplier: 2
        )

        #expect(policy.delay(forAttempt: 1, jitterPercent: 100) == .milliseconds(250))
        #expect(policy.delay(forAttempt: 2, jitterPercent: 100) == .milliseconds(500))
        #expect(policy.delay(forAttempt: 3, jitterPercent: 100) == .seconds(1))
        #expect(policy.delay(forAttempt: 4, jitterPercent: 100) == .seconds(2))
        #expect(policy.delay(forAttempt: 20, jitterPercent: 100) == .seconds(2))
        #expect(policy.delay(forAttempt: 4, jitterPercent: 80) == .milliseconds(1_600))
    }

    @Test
    func uncertainInputIsAttemptedExactlyOnce() async {
        let sender = FailingTerminalSender()
        let delivery = TerminalInputDelivery(sender: sender)

        await #expect(throws: TestFailure.self) {
            try await delivery.submitOnce(Data("dangerous-command\r".utf8))
        }
        #expect(await sender.calls == 1)
    }

    @Test
    @MainActor
    func terminalKeyboardInputIsForwardedWithoutBufferingOrRewriting() async throws {
        let transport = ScriptedTerminalTransport()
        let controller = TerminalSessionController(client: transport)

        controller.connect(
            hostText: "https://mac.tailnet.ts.net",
            sessionText: "fixture",
            credential: "valid-token"
        )
        try await transport.emit(.message(.ready))
        try await waitUntil { controller.connectionState == .connected }

        controller.bridge.receiveTerminalInput(Data("ls -la\r".utf8))
        try await waitUntil {
            await transport.sentMessages.contains(.input("ls -la\r"))
        }

        #expect(await transport.sentMessages.filter { $0 == .input("ls -la\r") }.count == 1)
        controller.stop()
    }

    @Test
    @MainActor
    func pasteUsesBracketedPasteWithoutExecutingTheCommand() async throws {
        let transport = ScriptedTerminalTransport()
        let controller = TerminalSessionController(client: transport)

        controller.connect(
            hostText: "https://mac.tailnet.ts.net",
            sessionText: "fixture",
            credential: "valid-token"
        )
        try await transport.emit(.message(.ready))
        try await waitUntil { controller.connectionState == .connected }

        controller.paste("echo safe")
        let expected = TerminalClientMessage.input("\u{1B}[200~echo safe\u{1B}[201~")
        try await waitUntil {
            await transport.sentMessages.contains(expected)
        }

        #expect(await transport.sentMessages.filter { $0 == expected }.count == 1)
        controller.stop()
    }

    @Test
    @MainActor
    func reattachingTheRendererRequestsATmuxRedraw() async throws {
        let transport = ScriptedTerminalTransport()
        let controller = TerminalSessionController(client: transport)
        let resize = TerminalClientMessage.resize(columns: 80, rows: 24)

        controller.connect(
            hostText: "https://mac.tailnet.ts.net",
            sessionText: "fixture",
            credential: "valid-token"
        )
        controller.terminalGridDidChange(TerminalGridSize(columns: 80, rows: 24))
        try await transport.emit(.message(.ready))
        try await waitUntil {
            await transport.sentMessages.filter { $0 == resize }.count == 1
        }

        controller.terminalRendererDidAttach()
        try await waitUntil {
            await transport.sentMessages.filter { $0 == resize }.count == 2
        }

        #expect(await transport.sentMessages.filter { $0 == resize }.count == 2)
        controller.stop()
    }

    @Test
    @MainActor
    func rapidTypingCoalescesBehindASlowSendWithoutReordering() async throws {
        let transport = GatedTerminalTransport()
        let controller = TerminalSessionController(client: transport)

        controller.connect(
            hostText: "https://mac.tailnet.ts.net",
            sessionText: "fixture",
            credential: "valid-token"
        )
        try await transport.emit(.message(.ready))
        try await waitUntil { controller.connectionState == .connected }

        controller.bridge.receiveTerminalInput(Data("a".utf8))
        try await waitUntil { await transport.inputMessages == ["a"] }

        let queuedText = "bcdefghijklmnopqrstuvwxyz"
        for byte in queuedText.utf8 {
            controller.bridge.receiveTerminalInput(Data([byte]))
        }
        await yieldExecution()
        #expect(await transport.inputMessages == ["a"])

        try await transport.resumeNextSend()
        try await waitUntil { await transport.inputMessages == ["a", queuedText] }
        try await transport.resumeNextSend()

        #expect(await transport.inputMessages.joined() == "a" + queuedText)
        controller.stop()
    }

    @Test
    @MainActor
    func permanentHandshakeFailureStopsRetriesAndStaysFailed() async throws {
        let transport = ScriptedTerminalTransport(connectError: .authenticationRejected)
        let controller = TerminalSessionController(
            client: transport,
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(5),
                maximumDelay: .milliseconds(5),
                multiplier: 1
            )
        )

        controller.connect(
            hostText: "https://mac.tailnet.ts.net",
            sessionText: "fixture",
            credential: "wrong-token"
        )
        try await waitUntil { controller.connectionState == .failed }
        await yieldExecution()

        #expect(await transport.connectCount == 1)
        #expect(controller.errorMessage?.contains("rejected") == true)
        controller.sceneWillResignActive()
        controller.sceneDidBecomeActive()
        #expect(controller.connectionState == .failed)
    }

    @Test
    @MainActor
    func missingHeartbeatPongTriggersReconnect() async throws {
        let sleeper = ManualTerminalSleeper()
        let transport = ScriptedTerminalTransport()
        let controller = TerminalSessionController(
            client: transport,
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .seconds(1),
                maximumDelay: .seconds(1),
                multiplier: 1
            ),
            heartbeatPolicy: HeartbeatPolicy(
                interval: .seconds(10),
                timeout: .seconds(5)
            ),
            timing: sleeper.timing
        )

        controller.connect(
            hostText: "https://mac.tailnet.ts.net",
            sessionText: "fixture",
            credential: "valid-token"
        )
        try await transport.emit(.message(.ready))
        try await waitUntil { await sleeper.hasWaiter(for: .seconds(10)) }
        try await sleeper.resumeFirst(for: .seconds(10))
        try await waitUntil { await sleeper.hasWaiter(for: .seconds(5)) }
        try await sleeper.resumeFirst(for: .seconds(5))
        try await waitUntil {
            if case .reconnecting = controller.connectionState { return true }
            return false
        }

        #expect(await transport.sentMessages.contains { message in
            if case .ping = message { return true }
            return false
        })
        #expect(controller.errorMessage?.contains("stopped responding") == true)
        controller.stop()
    }

    @Test
    @MainActor
    func matchingHeartbeatPongKeepsConnectionHealthy() async throws {
        let sleeper = ManualTerminalSleeper()
        let transport = ScriptedTerminalTransport()
        let controller = TerminalSessionController(
            client: transport,
            heartbeatPolicy: HeartbeatPolicy(
                interval: .seconds(10),
                timeout: .seconds(5)
            ),
            timing: sleeper.timing
        )

        controller.connect(
            hostText: "https://mac.tailnet.ts.net",
            sessionText: "fixture",
            credential: "valid-token"
        )
        try await transport.emit(.message(.ready))
        try await waitUntil { controller.connectionState == .connected }
        try await waitUntil { await sleeper.hasWaiter(for: .seconds(10)) }
        try await sleeper.resumeFirst(for: .seconds(10))
        let pingIdentifier = try await waitForPingIdentifier(in: transport)
        let receiveCount = await transport.receiveCount
        try await transport.emit(.message(.pong(identifier: pingIdentifier)))
        try await waitUntil { await transport.receiveCount > receiveCount }
        try await sleeper.resumeFirst(for: .seconds(5))
        await yieldExecution()

        #expect(controller.connectionState == .connected)
        #expect(await transport.sentMessages.contains { message in
            if case .ping = message { return true }
            return false
        })
        controller.stop()
    }

    @Test
    @MainActor
    func hangingHeartbeatSendStillTimesOut() async throws {
        let sleeper = ManualTerminalSleeper()
        let transport = ScriptedTerminalTransport(hangsSends: true)
        let controller = TerminalSessionController(
            client: transport,
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .seconds(20),
                maximumDelay: .seconds(20),
                multiplier: 1
            ),
            heartbeatPolicy: HeartbeatPolicy(
                interval: .seconds(10),
                timeout: .seconds(5)
            ),
            timing: sleeper.timing
        )

        controller.connect(
            hostText: "https://mac.tailnet.ts.net",
            sessionText: "fixture",
            credential: "valid-token"
        )
        try await transport.emit(.message(.ready))
        try await waitUntil { await sleeper.hasWaiter(for: .seconds(10)) }
        try await sleeper.resumeFirst(for: .seconds(10))
        _ = try await waitForPingIdentifier(in: transport)
        try await sleeper.resumeFirst(for: .seconds(5))
        try await waitUntil {
            if case .reconnecting = controller.connectionState { return true }
            return false
        }

        #expect(controller.errorMessage?.contains("stopped responding") == true)
        controller.stop()
    }

    @MainActor
    private func waitUntil(condition: () async -> Bool) async throws {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        throw TestFailure()
    }

    private func waitForPingIdentifier(
        in transport: ScriptedTerminalTransport
    ) async throws -> String {
        for _ in 0..<10_000 {
            if let identifier = await transport.latestPingIdentifier { return identifier }
            await Task.yield()
        }
        throw TestFailure()
    }

    private func yieldExecution() async {
        for _ in 0..<100 {
            await Task.yield()
        }
    }
}

private struct TestFailure: Error {}

private final class ScriptedPathObserver: NetworkPathObserving {
    private let stream: AsyncStream<NetworkPathSnapshot>
    private let continuation: AsyncStream<NetworkPathSnapshot>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func updates() -> AsyncStream<NetworkPathSnapshot> {
        stream
    }

    func emit(_ snapshot: NetworkPathSnapshot) {
        continuation.yield(snapshot)
    }
}

private actor FailingTerminalSender: TerminalMessageSending {
    private(set) var calls = 0

    func send(_ message: TerminalClientMessage) async throws {
        calls += 1
        throw TestFailure()
    }
}

private actor ScriptedTerminalTransport: TerminalTransporting {
    private(set) var connectCount = 0
    private(set) var receiveCount = 0
    private(set) var sentMessages: [TerminalClientMessage] = []

    private let connectError: TerminalTransportError?
    private let hangsSends: Bool
    private var connected = false
    private var queuedEvents: [TerminalTransportEvent] = []
    private var receiveContinuation: CheckedContinuation<TerminalTransportEvent, Never>?

    init(
        connectError: TerminalTransportError? = nil,
        hangsSends: Bool = false
    ) {
        self.connectError = connectError
        self.hangsSends = hangsSends
    }

    var latestPingIdentifier: String? {
        sentMessages.reversed().compactMap { message in
            if case let .ping(identifier) = message { return identifier }
            return nil
        }.first
    }

    func connect(configuration: TerminalConnectionConfiguration) throws {
        connectCount += 1
        if let connectError { throw connectError }
        connected = true
    }

    func receive() async -> TerminalTransportEvent {
        receiveCount += 1
        if !queuedEvents.isEmpty {
            return queuedEvents.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            receiveContinuation = continuation
        }
    }

    func send(_ message: TerminalClientMessage) async throws {
        sentMessages.append(message)
        if hangsSends {
            try await Task.sleep(for: .seconds(3_600))
        }
    }

    func disconnect() {
        guard connected else { return }
        connected = false
        enqueue(.disconnected)
    }

    func emit(_ event: TerminalTransportEvent) throws {
        enqueue(event)
    }

    private func enqueue(_ event: TerminalTransportEvent) {
        if let continuation = receiveContinuation {
            receiveContinuation = nil
            continuation.resume(returning: event)
        } else {
            queuedEvents.append(event)
        }
    }
}

private actor GatedTerminalTransport: TerminalTransporting {
    private(set) var inputMessages: [String] = []

    private var connected = false
    private var queuedEvents: [TerminalTransportEvent] = []
    private var receiveContinuation: CheckedContinuation<TerminalTransportEvent, Never>?
    private var sendContinuations: [CheckedContinuation<Void, Never>] = []

    func connect(configuration: TerminalConnectionConfiguration) {
        connected = true
    }

    func receive() async -> TerminalTransportEvent {
        if !queuedEvents.isEmpty {
            return queuedEvents.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            receiveContinuation = continuation
        }
    }

    func send(_ message: TerminalClientMessage) async {
        if case let .input(value) = message {
            inputMessages.append(value)
        }
        await withCheckedContinuation { continuation in
            sendContinuations.append(continuation)
        }
    }

    func disconnect() {
        guard connected else { return }
        connected = false
        enqueue(.disconnected)
        let continuations = sendContinuations
        sendContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func emit(_ event: TerminalTransportEvent) throws {
        enqueue(event)
    }

    func resumeNextSend() throws {
        guard !sendContinuations.isEmpty else { throw TestFailure() }
        sendContinuations.removeFirst().resume()
    }

    private func enqueue(_ event: TerminalTransportEvent) {
        if let continuation = receiveContinuation {
            receiveContinuation = nil
            continuation.resume(returning: event)
        } else {
            queuedEvents.append(event)
        }
    }
}

private actor ManualTerminalSleeper {
    private struct Waiter {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [Waiter] = []

    nonisolated var timing: TerminalTiming {
        TerminalTiming { duration in
            try await self.sleep(for: duration)
        }
    }

    func hasWaiter(for duration: Duration) -> Bool {
        waiters.contains { $0.duration == duration }
    }

    func resumeFirst(for duration: Duration) throws {
        guard let index = waiters.firstIndex(where: { $0.duration == duration }) else {
            throw TestFailure()
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume()
    }

    private func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(
                        Waiter(id: id, duration: duration, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
