import Foundation
@testable import Tavi
import Testing

struct TerminalWebSocketClientTests {
    // Network.framework reports a rejected upgrade without its HTTP status
    // (#70), so the client asks the host which permanent failure it was — and
    // only then. A transport error that is not a rejection never probes.
    @Test
    func classifiesRejectedHandshakesThroughTheProbeAndCancelsEachSocket() async throws {
        let unauthorized = FakeTerminalWebSocketTask(negotiatedProtocol: nil)
        unauthorized.enqueueFailure(NetworkWebSocketTask.Failure.handshakeRejected)
        let missing = FakeTerminalWebSocketTask(negotiatedProtocol: nil)
        missing.enqueueFailure(NetworkWebSocketTask.Failure.handshakeRejected)
        let transient = FakeTerminalWebSocketTask(negotiatedProtocol: nil)
        transient.enqueueFailure(NetworkWebSocketTask.Failure.handshakeRejected)
        let dropped = FakeTerminalWebSocketTask(negotiatedProtocol: nil)
        dropped.enqueueFailure(NetworkWebSocketTask.Failure.connectionFailed("path down"))
        let factory = FakeTerminalWebSocketFactory(tasks: [unauthorized, missing, transient, dropped])
        let probe = FakeHandshakeProbe(answers: [.authenticationRejected, .agentNotFound, nil])
        let client = TerminalWebSocketClient(makeSocket: factory.makeTask, handshakeProbe: probe)

        try await client.connect(configuration: connectionConfiguration(), resume: nil)
        #expect(await client.receive() == .failed(.authenticationRejected))
        try await client.connect(configuration: connectionConfiguration(), resume: nil)
        #expect(await client.receive() == .failed(.agentNotFound))
        try await client.connect(configuration: connectionConfiguration(), resume: nil)
        #expect(await client.receive() == .disconnected)
        try await client.connect(configuration: connectionConfiguration(), resume: nil)
        #expect(await client.receive() == .disconnected)

        #expect(unauthorized.cancelCodes == [.goingAway])
        #expect(missing.cancelCodes == [.goingAway])
        #expect(transient.cancelCodes == [.goingAway])
        #expect(dropped.cancelCodes == [.goingAway])
        #expect(probe.probedPanes == ["fixture", "fixture", "fixture"])
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(
            factory.requests.first?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol")
                == TerminalWireProtocol.name
        )
    }

    @Test
    func decodesBinaryOutputFramesAndSendsResumeQuery() async throws {
        let task = FakeTerminalWebSocketTask(negotiatedProtocol: TerminalWireProtocol.name)
        var frame = Data([TerminalWireProtocol.outputFrameType])
        let offset: UInt64 = 258
        for shift in stride(from: 56, through: 0, by: -8) {
            frame.append(UInt8(truncatingIfNeeded: offset >> UInt64(shift)))
        }
        frame.append(contentsOf: Data("delta".utf8))
        task.enqueueFrame(.data(frame))
        let factory = FakeTerminalWebSocketFactory(tasks: [task])
        let client = TerminalWebSocketClient(makeSocket: factory.makeTask)

        try await client.connect(
            configuration: connectionConfiguration(),
            resume: TerminalResumePoint(stream: "epoch-a", offset: 258)
        )
        #expect(
            await client.receive()
                == .message(.outputChunk(offset: 258, data: Data("delta".utf8)))
        )
        let query = factory.requests.first?.url?.query ?? ""
        #expect(query.contains("stream=epoch-a"))
        #expect(query.contains("resume=258"))
        await client.disconnect()
    }

    @Test
    func rejectsProtocolMismatchBinaryAndOversizedFramesWithTeardown() async throws {
        let mismatch = FakeTerminalWebSocketTask(negotiatedProtocol: "other.v1")
        mismatch.enqueueFrame(.string(#"{"type":"ready"}"#))
        let binary = FakeTerminalWebSocketTask(negotiatedProtocol: TerminalWireProtocol.name)
        binary.enqueueFrame(.data(Data(#"{"type":"ready"}"#.utf8)))
        let oversized = FakeTerminalWebSocketTask(negotiatedProtocol: TerminalWireProtocol.name)
        oversized.enqueueFrame(
            .string(
                String(repeating: "x", count: TerminalWireProtocol.maximumFrameBytes + 1)
            )
        )
        let factory = FakeTerminalWebSocketFactory(tasks: [mismatch, binary, oversized])
        let client = TerminalWebSocketClient(makeSocket: factory.makeTask)

        try await client.connect(configuration: connectionConfiguration(), resume: nil)
        #expect(await client.receive() == .failed(.protocolMismatch))
        try await client.connect(configuration: connectionConfiguration(), resume: nil)
        #expect(await client.receive() == .failed(.invalidFrame))
        try await client.connect(configuration: connectionConfiguration(), resume: nil)
        #expect(await client.receive() == .failed(.oversizedFrame))

        #expect(mismatch.cancelCodes == [.protocolError])
        #expect(binary.cancelCodes == [.protocolError])
        #expect(oversized.cancelCodes == [.protocolError])
    }

    // The third takeover signal (#108): close 1000 with reason `superseded`,
    // and only that. A 1000 with no reason, or the reason under any other
    // code, stays an ordinary drop the controller retries — a takeover would
    // stop it retrying at all.
    @Test
    func onlyANormalCloseCarryingTheSupersededReasonIsATakeover() async throws {
        let takenOver = FakeTerminalWebSocketTask(negotiatedProtocol: TerminalWireProtocol.name)
        takenOver.enqueueFailure(NetworkWebSocketTask.Failure.closed(code: 1_000, reason: "superseded"))
        let unexplained = FakeTerminalWebSocketTask(negotiatedProtocol: TerminalWireProtocol.name)
        unexplained.enqueueFailure(NetworkWebSocketTask.Failure.closed(code: 1_000, reason: nil))
        let otherCode = FakeTerminalWebSocketTask(negotiatedProtocol: TerminalWireProtocol.name)
        otherCode.enqueueFailure(NetworkWebSocketTask.Failure.closed(code: 1_011, reason: "superseded"))
        let factory = FakeTerminalWebSocketFactory(tasks: [takenOver, unexplained, otherCode])
        let client = TerminalWebSocketClient(makeSocket: factory.makeTask)

        try await client.connect(configuration: connectionConfiguration(), resume: nil)
        #expect(await client.receive() == .takenOver)
        try await client.connect(configuration: connectionConfiguration(), resume: nil)
        #expect(await client.receive() == .disconnected)
        try await client.connect(configuration: connectionConfiguration(), resume: nil)
        #expect(await client.receive() == .disconnected)

        #expect(takenOver.cancelCodes == [.normalClosure])
        #expect(unexplained.cancelCodes == [.goingAway])
        #expect(otherCode.cancelCodes == [.goingAway])
    }

    @Test
    func staleSocketCannotPublishIntoTheReplacementConnection() async throws {
        let stale = FakeTerminalWebSocketTask(
            negotiatedProtocol: TerminalWireProtocol.name,
            resumesReceiveOnCancel: false
        )
        let replacement = FakeTerminalWebSocketTask(negotiatedProtocol: TerminalWireProtocol.name)
        replacement.enqueueFrame(.string(#"{"type":"ready"}"#))
        let factory = FakeTerminalWebSocketFactory(tasks: [stale, replacement])
        let client = TerminalWebSocketClient(makeSocket: factory.makeTask)

        try await client.connect(configuration: connectionConfiguration(), resume: nil)
        let staleReceive = Task { await client.receive() }
        try await waitUntil { stale.hasPendingReceive }
        await client.disconnect()
        try await client.connect(configuration: connectionConfiguration(), resume: nil)
        stale.enqueueFrame(.string(#"{"type":"output","data":"stale"}"#))

        #expect(await staleReceive.value == .disconnected)
        #expect(await client.receive() == .message(.ready(stream: nil, offset: 0, resumed: false)))
        #expect(stale.cancelCodes == [.normalClosure])
        #expect(replacement.cancelCodes.isEmpty)
        await client.disconnect()
        #expect(replacement.cancelCodes == [.normalClosure])
    }

    private func connectionConfiguration() throws -> TerminalConnectionConfiguration {
        try TerminalConnectionConfiguration(
            host: Fixtures.hostEndpoint("https://mac.tailnet.ts.net"),
            paneID: "fixture",
            credential: "secret"
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        throw StubSocketError.timedOut
    }
}

private enum StubSocketError: Error {
    case failed
    case timedOut
}

private final class FakeHandshakeProbe: TerminalHandshakeProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [TerminalTransportError?]
    private var panes: [String] = []

    init(answers: [TerminalTransportError?]) {
        self.answers = answers
    }

    var probedPanes: [String] {
        lock.withLock { panes }
    }

    func classify(_ configuration: TerminalConnectionConfiguration) async -> TerminalTransportError? {
        lock.withLock {
            panes.append(configuration.paneID)
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }
}

private final class FakeTerminalWebSocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingTasks: [FakeTerminalWebSocketTask]
    private var capturedRequests: [URLRequest] = []

    init(tasks: [FakeTerminalWebSocketTask]) {
        remainingTasks = tasks
    }

    var requests: [URLRequest] {
        lock.withLock { capturedRequests }
    }

    func makeTask(request: URLRequest) -> any TerminalWebSocketTasking {
        lock.withLock {
            capturedRequests.append(request)
            return remainingTasks.removeFirst()
        }
    }
}

private final class FakeTerminalWebSocketTask: TerminalWebSocketTasking, @unchecked Sendable {
    private enum ReceiveAction {
        case failure(any Error)
        case frame(URLSessionWebSocketTask.Message)
    }

    let negotiatedProtocol: String?

    private let lock = NSLock()
    private let resumesReceiveOnCancel: Bool
    private var actions: [ReceiveAction] = []
    private var cancelHistory: [URLSessionWebSocketTask.CloseCode] = []
    private var pendingReceive: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var resumed = false
    private var sentMessages: [URLSessionWebSocketTask.Message] = []

    init(negotiatedProtocol: String?, resumesReceiveOnCancel: Bool = true) {
        self.negotiatedProtocol = negotiatedProtocol
        self.resumesReceiveOnCancel = resumesReceiveOnCancel
    }

    var cancelCodes: [URLSessionWebSocketTask.CloseCode] {
        lock.withLock { cancelHistory }
    }

    var hasPendingReceive: Bool {
        lock.withLock { pendingReceive != nil }
    }

    func resume() {
        lock.withLock { resumed = true }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            let action = lock.withLock { () -> ReceiveAction? in
                guard !actions.isEmpty else {
                    pendingReceive = continuation
                    return nil
                }
                return actions.removeFirst()
            }
            resume(continuation, with: action)
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        lock.withLock { sentMessages.append(message) }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>? = lock.withLock {
            cancelHistory.append(closeCode)
            guard resumesReceiveOnCancel else { return nil }
            defer { pendingReceive = nil }
            return pendingReceive
        }
        continuation?.resume(throwing: CancellationError())
    }

    func enqueueFrame(_ frame: URLSessionWebSocketTask.Message) {
        enqueue(.frame(frame))
    }

    func enqueueFailure(_ error: any Error) {
        enqueue(.failure(error))
    }

    private func enqueue(_ action: ReceiveAction) {
        let continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>? = lock.withLock {
            guard let pendingReceive else {
                actions.append(action)
                return nil
            }
            self.pendingReceive = nil
            return pendingReceive
        }
        resume(continuation, with: action)
    }

    private func resume(
        _ continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?,
        with action: ReceiveAction?
    ) {
        guard let continuation, let action else { return }
        switch action {
        case let .failure(error):
            continuation.resume(throwing: error)
        case let .frame(frame):
            continuation.resume(returning: frame)
        }
    }
}
