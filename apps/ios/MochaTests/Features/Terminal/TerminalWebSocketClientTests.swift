import Foundation
import Testing
@testable import Mocha

struct TerminalWebSocketClientTests {
    @Test
    func classifiesPermanentHandshakeFailuresAndCancelsEachSocket() async throws {
        let unauthorized = FakeTerminalWebSocketTask(response: response(status: 401))
        unauthorized.enqueueFailure(StubSocketError.failed)
        let missing = FakeTerminalWebSocketTask(response: response(status: 404))
        missing.enqueueFailure(StubSocketError.failed)
        let factory = FakeTerminalWebSocketFactory(tasks: [unauthorized, missing])
        let client = TerminalWebSocketClient(makeSocket: factory.makeTask)

        try await client.connect(configuration: connectionConfiguration(), resume: nil)
        #expect(await client.receive() == .failed(.authenticationRejected))
        try await client.connect(configuration: connectionConfiguration(), resume: nil)
        #expect(await client.receive() == .failed(.agentNotFound))

        #expect(unauthorized.cancelCodes == [.goingAway])
        #expect(missing.cancelCodes == [.goingAway])
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(
            factory.requests.first?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol")
                == TerminalWireProtocol.name
        )
    }

    @Test
    func decodesBinaryOutputFramesAndSendsResumeQuery() async throws {
        let task = FakeTerminalWebSocketTask(response: acceptedResponse())
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
        let mismatch = FakeTerminalWebSocketTask(
            response: response(status: 101, protocolName: "other.v1")
        )
        mismatch.enqueueFrame(.string(#"{"type":"ready"}"#))
        let binary = FakeTerminalWebSocketTask(response: acceptedResponse())
        binary.enqueueFrame(.data(Data(#"{"type":"ready"}"#.utf8)))
        let oversized = FakeTerminalWebSocketTask(response: acceptedResponse())
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

    @Test
    func staleSocketCannotPublishIntoTheReplacementConnection() async throws {
        let stale = FakeTerminalWebSocketTask(
            response: acceptedResponse(),
            resumesReceiveOnCancel: false
        )
        let replacement = FakeTerminalWebSocketTask(response: acceptedResponse())
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
            host: HostEndpoint(baseURL: #require(URL(string: "https://mac.tailnet.ts.net"))),
            paneID: "fixture",
            credential: "secret"
        )
    }

    private func acceptedResponse() -> HTTPURLResponse {
        response(status: 101, protocolName: TerminalWireProtocol.name)
    }

    private func response(status: Int, protocolName: String? = nil) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let protocolName {
            headers["Sec-WebSocket-Protocol"] = protocolName
        }
        return HTTPURLResponse(
            url: URL(string: "https://mac.tailnet.ts.net")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
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

    let response: URLResponse?

    private let lock = NSLock()
    private let resumesReceiveOnCancel: Bool
    private var actions: [ReceiveAction] = []
    private var cancelHistory: [URLSessionWebSocketTask.CloseCode] = []
    private var pendingReceive: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var resumed = false
    private var sentMessages: [URLSessionWebSocketTask.Message] = []

    init(response: URLResponse?, resumesReceiveOnCancel: Bool = true) {
        self.response = response
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
