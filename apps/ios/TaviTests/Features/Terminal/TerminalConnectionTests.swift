// swiftlint:disable file_length - over the 400-line line; removed when #101 splits this suite on its own seams.

import Foundation
@testable import Tavi
import Testing

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
            paneID: "fixture",
            credential: "valid-token"
        )
        try await transport.emit(.message(.ready(stream: "epoch-1", offset: 0, resumed: false)))
        try await waitFor { controller.connectionState == .connected }

        paths.emit(NetworkPathSnapshot(isSatisfied: false, interfaceIdentity: "none"))
        try await waitFor { controller.connectionState == .waitingForNetwork }

        paths.emit(NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "en0"))
        try await waitFor { await transport.connectCount >= 2 }
        try await transport.emit(.message(.ready(stream: "epoch-1", offset: 0, resumed: false)))
        try await waitFor { controller.connectionState == .connected }
        controller.stop()
    }

    @Test
    @MainActor
    func interfaceFlipWhileConnectedAsksTheHeartbeatInsteadOfCycling() async throws {
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
            paneID: "fixture",
            credential: "valid-token"
        )
        try await transport.emit(.message(.ready(stream: "epoch-1", offset: 0, resumed: false)))
        try await waitFor { controller.connectionState == .connected }

        paths.emit(NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "en0"))
        await settle()
        #expect(await transport.connectCount == 1)

        // A path *change* while connected (#86, PRD §7.13): on cellular the
        // interface list changes at every handover and most leave a working
        // socket working. The socket is asked, not torn down; its heartbeat
        // timeout decides.
        paths.emit(NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "pdp_ip0"))
        try await waitFor { await transport.latestPingIdentifier != nil }
        #expect(await transport.connectCount == 1)
        #expect(controller.connectionState == .connected)
        controller.stop()
    }

    @Test
    @MainActor
    func stalledConnectAttemptIsCycledAtTheDeadline() async throws {
        let clock = ManualTerminalClock()
        let transport = ScriptedTerminalTransport()
        let controller = TerminalSessionController(
            client: transport,
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .seconds(60),
                maximumDelay: .seconds(60),
                multiplier: 1,
                connectDeadline: .seconds(3)
            ),
            timing: clock.timing
        )

        controller.connect(
            hostText: "https://mac.tailnet.ts.net",
            paneID: "fixture",
            credential: "valid-token"
        )
        #expect(controller.connectionState == .connecting)
        try await waitFor { await clock.hasWaiter(for: .seconds(3)) }
        try await clock.resumeAll(for: .seconds(3))
        try await waitFor {
            if case .reconnecting = controller.connectionState { return true }
            return false
        }
        controller.stop()
    }

    @Test
    @MainActor
    func reconnectResumesFromTheExactByteOffset() async throws {
        let transport = ScriptedTerminalTransport()
        let controller = TerminalSessionController(
            client: transport,
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(1),
                maximumDelay: .milliseconds(1),
                multiplier: 1,
                connectDeadline: .seconds(60)
            )
        )

        controller.connect(
            hostText: "https://mac.tailnet.ts.net",
            paneID: "fixture",
            credential: "valid-token"
        )
        try await transport.emit(.message(.ready(stream: "epoch-a", offset: 0, resumed: false)))
        try await waitFor { controller.connectionState == .connected }
        try await transport.emit(.message(.outputChunk(offset: 0, data: Data("hello".utf8))))
        try await transport.emit(.message(.outputChunk(offset: 5, data: Data(" world".utf8))))
        try await waitFor { await transport.receiveCount >= 3 }

        try await transport.emit(.disconnected)
        try await waitFor { await transport.connectCount >= 2 }

        let resumes = await transport.connectResumes
        #expect(resumes.first ?? nil == nil)
        #expect(resumes.last ?? nil == TerminalResumePoint(stream: "epoch-a", offset: 11))
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

        await #expect(throws: TerminalTestFailure.self) {
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
            paneID: "fixture",
            credential: "valid-token"
        )
        try await transport.emit(.message(.ready(stream: "epoch-1", offset: 0, resumed: false)))
        try await waitFor { controller.connectionState == .connected }

        controller.bridge.receiveTerminalInput(Data("ls -la\r".utf8))
        try await waitFor {
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
            paneID: "fixture",
            credential: "valid-token"
        )
        try await transport.emit(.message(.ready(stream: "epoch-1", offset: 0, resumed: false)))
        try await waitFor { controller.connectionState == .connected }

        controller.paste("echo safe")
        let expected = TerminalClientMessage.input("\u{1B}[200~echo safe\u{1B}[201~")
        try await waitFor {
            await transport.sentMessages.contains(expected)
        }

        #expect(await transport.sentMessages.filter { $0 == expected }.count == 1)
        controller.stop()
    }

    @Test
    @MainActor
    func composerSendUsesBracketedPasteWithOneExplicitReturn() async throws {
        let transport = ScriptedTerminalTransport()
        let controller = TerminalSessionController(client: transport)

        controller.connect(
            hostText: "https://mac.tailnet.ts.net",
            paneID: "fixture",
            credential: "valid-token"
        )
        try await transport.emit(.message(.ready(stream: "epoch-1", offset: 0, resumed: false)))
        try await waitFor { controller.connectionState == .connected }

        controller.sendComposedText("line one\nline two")
        let pasted = TerminalClientMessage.input("\u{1B}[200~line one\nline two\u{1B}[201~")
        let returnKey = TerminalClientMessage.input("\r")
        try await waitFor {
            await transport.sentMessages.contains(returnKey)
        }

        let sent = await transport.sentMessages
        #expect(sent.filter { $0 == pasted }.count == 1)
        let pasteIndex = try #require(sent.firstIndex(of: pasted))
        let returnIndex = try #require(sent.firstIndex(of: returnKey))
        #expect(pasteIndex < returnIndex)
        controller.stop()
    }

    @Test
    @MainActor
    func controlLatchTransformsExactlyOneKeystroke() async throws {
        let transport = ScriptedTerminalTransport()
        let controller = TerminalSessionController(client: transport)

        controller.connect(
            hostText: "https://mac.tailnet.ts.net",
            paneID: "fixture",
            credential: "valid-token"
        )
        try await transport.emit(.message(.ready(stream: "epoch-1", offset: 0, resumed: false)))
        try await waitFor { controller.connectionState == .connected }

        controller.toggleControlLatch()
        #expect(controller.controlLatchActive)
        controller.bridge.receiveTerminalInput(Data("r".utf8))
        try await waitFor {
            await transport.sentMessages.contains(.input("\u{12}"))
        }
        #expect(!controller.controlLatchActive)

        controller.bridge.receiveTerminalInput(Data("r".utf8))
        try await waitFor {
            await transport.sentMessages.contains(.input("r"))
        }
        controller.stop()
    }

    @Test
    @MainActor
    func reattachingTheRendererRequestsARedraw() async throws {
        let transport = ScriptedTerminalTransport()
        let controller = TerminalSessionController(client: transport)
        let resize = TerminalClientMessage.resize(columns: 80, rows: 24)

        controller.connect(
            hostText: "https://mac.tailnet.ts.net",
            paneID: "fixture",
            credential: "valid-token"
        )
        controller.terminalGridDidChange(TerminalGridSize(columns: 80, rows: 24))
        try await transport.emit(.message(.ready(stream: "epoch-1", offset: 0, resumed: false)))
        try await waitFor {
            await transport.sentMessages.filter { $0 == resize }.count == 1
        }

        controller.terminalRendererDidAttach()
        try await waitFor {
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
            paneID: "fixture",
            credential: "valid-token"
        )
        try await transport.emit(.message(.ready(stream: "epoch-1", offset: 0, resumed: false)))
        try await waitFor { controller.connectionState == .connected }

        controller.bridge.receiveTerminalInput(Data("a".utf8))
        try await waitFor { await transport.inputMessages == ["a"] }

        let queuedText = "bcdefghijklmnopqrstuvwxyz"
        for byte in queuedText.utf8 {
            controller.bridge.receiveTerminalInput(Data([byte]))
        }
        await settle()
        #expect(await transport.inputMessages == ["a"])

        try await transport.resumeNextSend()
        try await waitFor { await transport.inputMessages == ["a", queuedText] }
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
            paneID: "fixture",
            credential: "wrong-token"
        )
        try await waitFor { controller.connectionState == .failed }
        await settle()

        #expect(await transport.connectCount == 1)
        #expect(controller.errorMessage?.contains("rejected") == true)
        controller.sceneWillResignActive()
        controller.sceneDidBecomeActive()
        #expect(controller.connectionState == .failed)
    }

    @Test
    @MainActor
    func missingHeartbeatPongTriggersReconnect() async throws {
        let clock = ManualTerminalClock()
        let transport = ScriptedTerminalTransport()
        let controller = TerminalSessionController(
            client: transport,
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .seconds(1),
                maximumDelay: .seconds(1),
                multiplier: 1
            ),
            // Three distinct budgets, so resuming one says which bound the
            // connection was cycled on (#107).
            heartbeatPolicy: HeartbeatPolicy(
                interval: .seconds(10),
                timeout: .seconds(5),
                sendTimeout: .seconds(2)
            ),
            timing: clock.timing
        )

        controller.connect(
            hostText: "https://mac.tailnet.ts.net",
            paneID: "fixture",
            credential: "valid-token"
        )
        try await transport.emit(.message(.ready(stream: "epoch-1", offset: 0, resumed: false)))
        try await waitFor { await clock.hasWaiter(for: .seconds(10)) }
        try await clock.resumeAll(for: .seconds(10))
        // The ping is on the wire and the host's own budget is running: this
        // is the missing-pong path, not the stalled-send one.
        try await waitFor { await transport.latestPingIdentifier != nil }
        try await waitFor { await clock.hasWaiter(for: .seconds(5)) }
        try await clock.resumeAll(for: .seconds(5))
        try await waitFor {
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
        let clock = ManualTerminalClock()
        let transport = ScriptedTerminalTransport()
        let controller = TerminalSessionController(
            client: transport,
            heartbeatPolicy: HeartbeatPolicy(
                interval: .seconds(10),
                timeout: .seconds(5),
                sendTimeout: .seconds(2)
            ),
            timing: clock.timing
        )

        controller.connect(
            hostText: "https://mac.tailnet.ts.net",
            paneID: "fixture",
            credential: "valid-token"
        )
        try await transport.emit(.message(.ready(stream: "epoch-1", offset: 0, resumed: false)))
        try await waitFor { controller.connectionState == .connected }
        try await waitFor { await clock.hasWaiter(for: .seconds(10)) }
        try await clock.resumeAll(for: .seconds(10))
        let pingIdentifier = try await waitForPingIdentifier(in: transport)
        try await waitFor { await clock.hasWaiter(for: .seconds(5)) }
        try await transport.emit(.message(.pong(identifier: pingIdentifier)))
        // The answer released the round rather than being ignored until the
        // budget ran out: the next beat is one interval away (#107).
        try await waitFor { await clock.hasWaiter(for: .seconds(5)) == false }
        try await waitFor { await clock.hasWaiter(for: .seconds(10)) }
        await settle()

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
        let clock = ManualTerminalClock()
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
                timeout: .seconds(5),
                sendTimeout: .seconds(2)
            ),
            timing: clock.timing
        )

        controller.connect(
            hostText: "https://mac.tailnet.ts.net",
            paneID: "fixture",
            credential: "valid-token"
        )
        try await transport.emit(.message(.ready(stream: "epoch-1", offset: 0, resumed: false)))
        try await waitFor { await clock.hasWaiter(for: .seconds(10)) }
        try await clock.resumeAll(for: .seconds(10))
        _ = try await waitForPingIdentifier(in: transport)
        // The send never completes, so this is the send bound; the host's
        // budget was never armed because nothing was ever asked.
        try await waitFor { await clock.hasWaiter(for: .seconds(2)) }
        #expect(await clock.timesScheduled(.seconds(5)) == 0)
        try await clock.resumeAll(for: .seconds(2))
        try await waitFor {
            if case .reconnecting = controller.connectionState { return true }
            return false
        }

        #expect(controller.errorMessage?.contains("stopped responding") == true)
        controller.stop()
    }

    @MainActor
    private func waitForPingIdentifier(
        in transport: ScriptedTerminalTransport
    ) async throws -> String {
        try await waitFor { await transport.latestPingIdentifier != nil }
        guard let identifier = await transport.latestPingIdentifier else {
            throw TerminalTestFailure()
        }
        return identifier
    }
}

private actor FailingTerminalSender: TerminalMessageSending {
    private(set) var calls = 0

    func send(_ message: TerminalClientMessage) async throws {
        calls += 1
        throw TerminalTestFailure()
    }
}

private actor ScriptedTerminalTransport: TerminalTransporting {
    private(set) var connectCount = 0
    private(set) var connectResumes: [TerminalResumePoint?] = []
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

    func connect(configuration: TerminalConnectionConfiguration, resume: TerminalResumePoint?) throws {
        connectCount += 1
        connectResumes.append(resume)
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

    func connect(configuration: TerminalConnectionConfiguration, resume: TerminalResumePoint?) {
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
        guard !sendContinuations.isEmpty else { throw TerminalTestFailure() }
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
