import Foundation
import Network

// A WebSocket on Network.framework, with the same surface the app used from
// URLSessionWebSocketTask so both callers (the terminal client and the
// events stream) swap transports without changing shape.
//
// Why not URLSessionWebSocketTask (#70, measured 2026-09-02): every new
// WebSocket task to the same host inherits a CFNetwork pre-connect block
// that captured the previous task's connection, so each terminal open or
// reconnect pinned ~40 KB for the life of the process (242 completed tasks
// and 2 916 certificates in the heap after 200 trips; unchanged by fresh
// sessions, invalidateAndCancel, or plain ws). The same 50 connect → frame →
// close cycles on NWConnection + NWProtocolWebSocket left nothing behind.
//
// What Network.framework does not give: the HTTP status of a rejected
// upgrade. A 401/404/400 from the host surfaces as `.waiting(ECONNABORTED)`
// after the request was written, and the connection would retry on its own
// forever; this task reports it once as `handshakeRejected` and cancels.
// Callers that need to tell "revoked" from "pane gone" ask the host over
// HTTP (see TerminalHandshakeProbe).
final class NetworkWebSocketTask: TerminalWebSocketTasking, @unchecked Sendable {
    enum Failure: Error, Equatable {
        // The host answered the upgrade with something other than 101.
        case handshakeRejected
        // The path, TCP, TLS or the WebSocket layer failed.
        case connectionFailed(String)
        // The peer sent a close frame. Network.framework delivers the reason
        // as the frame's UTF-8 content, not as close metadata.
        case closed(code: UInt16?, reason: String?)
        // cancel(with:) or deinit ended the connection first.
        case cancelled
        case notConnected
    }

    private enum Phase {
        case idle
        case connecting
        case ready(subprotocol: String?)
        case ended(Failure)
    }

    private static let queue = DispatchQueue(label: "com.farfield.tavi.websocket", qos: .userInitiated)
    // Frames are bounded by the protocols (64 KB terminal, one agents
    // snapshot); this is only a ceiling against a misbehaving peer.
    private static let maximumMessageBytes = 4 * 1_024 * 1_024

    private let connection: NWConnection
    private let lock = NSLock()
    private var phase: Phase = .idle
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var pendingReceive: OnceContinuation<URLSessionWebSocketTask.Message>?
    private var cancelRequested = false
    // When the last frame of any kind (data, ping, pong, close) arrived —
    // the idle clock a caller's heartbeat runs on (#86).
    private var lastActivityStorage = ContinuousClock().now
    var lastActivity: ContinuousClock.Instant { lock.withLock { lastActivityStorage } }
    // When the peer last delivered a frame; `lastActivity` also moves for
    // the completion that ends a socket, which is not life (#111).
    private var lastFrameStorage = ContinuousClock().now
    var lastFrameAt: ContinuousClock.Instant { lock.withLock { lastFrameStorage } }
    // Where pong payloads go, so a challenge can find its own answer. The
    // payload is the caller's bytes and is never logged (#111).
    private var pongHandler: (@Sendable (Data) -> Void)?

    init(request: URLRequest) {
        let url = request.url ?? URL(string: "wss://invalid.invalid")!
        let secure = ["wss", "https"].contains(url.scheme?.lowercased() ?? "")

        let tcp = NWProtocolTCP.Options()
        // Terminal keystrokes are tiny writes; never let Nagle hold one back.
        tcp.noDelay = true
        // URLRequest's timeout becomes the TCP connection budget and nothing
        // more; Network.framework's own default is a minute.
        if request.timeoutInterval.isFinite, request.timeoutInterval >= 1 {
            tcp.connectionTimeout = Int(request.timeoutInterval)
        }
        let parameters = NWParameters(tls: secure ? NWProtocolTLS.Options() : nil, tcp: tcp)

        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = Self.maximumMessageBytes
        var headers: [(String, String)] = []
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            if name.caseInsensitiveCompare("Sec-WebSocket-Protocol") == .orderedSame {
                websocket.setSubprotocols(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            } else {
                headers.append((name, value))
            }
        }
        if !headers.isEmpty {
            websocket.setAdditionalHeaders(headers)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

        connection = NWConnection(to: .url(url), using: parameters)
    }

    deinit {
        connection.cancel()
    }

    var negotiatedProtocol: String? {
        lock.withLock {
            if case let .ready(subprotocol) = phase { return subprotocol }
            return nil
        }
    }

    func resume() {
        let start: Bool = lock.withLock {
            guard case .idle = phase else { return false }
            phase = .connecting
            return true
        }
        guard start else { return }
        connection.stateUpdateHandler = { [weak self] state in
            self?.connectionStateChanged(state)
        }
        connection.start(queue: Self.queue)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await waitUntilReady()
        while true {
            let once = OnceContinuation<URLSessionWebSocketTask.Message>()
            let message: URLSessionWebSocketTask.Message? = try await withCheckedThrowingContinuation { continuation in
                once.attach(continuation)
                let proceed: Bool = lock.withLock {
                    guard case .ready = phase else { return false }
                    pendingReceive = once
                    return true
                }
                guard proceed else {
                    once.resume(throwing: endedFailure())
                    return
                }
                connection.receiveMessage { [weak self] content, context, _, error in
                    guard let self else {
                        once.resume(throwing: Failure.cancelled)
                        return
                    }
                    self.lock.withLock {
                        if self.pendingReceive === once { self.pendingReceive = nil }
                        self.lastActivityStorage = ContinuousClock().now
                    }
                    if let error {
                        once.resume(throwing: self.fail(with: .connectionFailed(error.localizedDescription)))
                        return
                    }
                    let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                    switch metadata?.opcode {
                    case .text?:
                        self.stampFrame()
                        once.resume(returning: .string(String(decoding: content ?? Data(), as: UTF8.self)))
                    case .binary?:
                        self.stampFrame()
                        once.resume(returning: .data(content ?? Data()))
                    case .close?:
                        var code: UInt16?
                        if case let .protocolCode(defined) = metadata?.closeCode { code = defined.rawValue }
                        if case let .applicationCode(value) = metadata?.closeCode { code = value }
                        if case let .privateCode(value) = metadata?.closeCode { code = value }
                        let reason = (content?.isEmpty ?? true) ? nil : String(bytes: content ?? Data(), encoding: .utf8)
                        once.resume(throwing: self.fail(with: .closed(code: code, reason: reason)))
                    case .pong?:
                        // The answer to whichever challenge sent this payload.
                        self.stampFrame()
                        self.lock.withLock { self.pongHandler }?(content ?? Data())
                        once.resume(returning: nil)
                    case .ping?, .cont?:
                        // Control frames are handled by the stack; ask again.
                        self.stampFrame()
                        once.resume(returning: nil)
                    default:
                        // A completed receive with no frame is the peer going away.
                        once.resume(throwing: self.fail(with: .closed(code: nil, reason: nil)))
                    }
                }
            }
            if let message { return message }
        }
    }

    private func stampFrame() {
        lock.withLock { lastFrameStorage = ContinuousClock().now }
    }

    // Set before `resume()`; the socket holds it for its life.
    func onPong(_ handler: @escaping @Sendable (Data) -> Void) {
        lock.withLock { pongHandler = handler }
    }

    // A WebSocket ping; the peer's stack answers with a pong carrying the
    // same payload, which lands on `lastActivity` and on `onPong`. Silence
    // past that is the socket's own verdict.
    func ping(payload: Data) async throws {
        let ready: Bool = lock.withLock {
            if case .ready = phase { return true }
            return false
        }
        guard ready else { throw Failure.notConnected }
        let context = NWConnection.ContentContext(
            identifier: "ping",
            metadata: [NWProtocolWebSocket.Metadata(opcode: .ping)]
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: Failure.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let ready: Bool = lock.withLock {
            if case .ready = phase { return true }
            return false
        }
        guard ready else { throw Failure.notConnected }

        let content: Data
        let opcode: NWProtocolWebSocket.Opcode
        switch message {
        case let .string(text):
            content = Data(text.utf8)
            opcode = .text
        case let .data(data):
            content = data
            opcode = .binary
        @unknown default:
            throw Failure.notConnected
        }
        let context = NWConnection.ContentContext(
            identifier: "frame",
            metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)]
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: content, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: Failure.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // Sends the close frame the protocol expects, then cancels. Idempotent;
    // safe from any thread. A close whose frame never gets written (dead
    // path) is still cancelled a second later.
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let wasReady: Bool = lock.withLock {
            guard !cancelRequested else { return false }
            cancelRequested = true
            if case .ready = phase {
                phase = .ended(.cancelled)
                return true
            }
            if case .ended = phase {} else { phase = .ended(.cancelled) }
            return false
        }
        finishWaiters(with: .cancelled)
        guard wasReady else {
            connection.cancel()
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        if let defined = NWProtocolWebSocket.CloseCode.Defined(rawValue: UInt16(closeCode.rawValue)) {
            metadata.closeCode = .protocolCode(defined)
        } else {
            metadata.closeCode = .applicationCode(UInt16(clamping: closeCode.rawValue))
        }
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        let connection = self.connection
        connection.send(content: reason, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
        Self.queue.asyncAfter(deadline: .now() + .seconds(1)) {
            connection.cancel()
        }
    }

    // MARK: - Connection state

    private func connectionStateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            let metadata = connection.metadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            let waiters: [CheckedContinuation<Void, Error>] = lock.withLock {
                guard case .connecting = phase else { return [] }
                phase = .ready(subprotocol: metadata?.selectedSubprotocol)
                defer { readyWaiters.removeAll() }
                return readyWaiters
            }
            waiters.forEach { $0.resume() }
        case let .waiting(error):
            // The host rejected the upgrade, or the path is not usable. The
            // callers own retry timing; a connection that waits on its own
            // would hide both behind "Connecting…".
            let failure: Failure = Self.isRejectedUpgrade(error) ? .handshakeRejected : .connectionFailed(error.localizedDescription)
            _ = fail(with: failure)
            connection.cancel()
        case let .failed(error):
            _ = fail(with: .connectionFailed(error.localizedDescription))
            connection.cancel()
        case .cancelled:
            _ = fail(with: .cancelled)
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private static func isRejectedUpgrade(_ error: NWError) -> Bool {
        if case let .posix(code) = error, code == .ECONNABORTED { return true }
        return false
    }

    // Records the first failure (later ones keep the first, which is the
    // cause) and releases anyone waiting on the connection.
    @discardableResult
    private func fail(with failure: Failure) -> Failure {
        let recorded: Failure = lock.withLock {
            if case let .ended(existing) = phase { return existing }
            phase = .ended(failure)
            return failure
        }
        finishWaiters(with: recorded)
        return recorded
    }

    private func finishWaiters(with failure: Failure) {
        let (waiters, receive): ([CheckedContinuation<Void, Error>], OnceContinuation<URLSessionWebSocketTask.Message>?) = lock.withLock {
            defer {
                readyWaiters.removeAll()
                pendingReceive = nil
            }
            return (readyWaiters, pendingReceive)
        }
        waiters.forEach { $0.resume(throwing: failure) }
        receive?.resume(throwing: failure)
    }

    private func endedFailure() -> Failure {
        lock.withLock {
            if case let .ended(failure) = phase { return failure }
            return .notConnected
        }
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let outcome: Result<Void, Failure>? = lock.withLock {
                switch phase {
                case .ready:
                    return .success(())
                case let .ended(failure):
                    return .failure(failure)
                case .idle:
                    return .failure(.notConnected)
                case .connecting:
                    readyWaiters.append(continuation)
                    return nil
                }
            }
            switch outcome {
            case .success?:
                continuation.resume()
            case let .failure(failure)?:
                continuation.resume(throwing: failure)
            case nil:
                break
            }
        }
    }
}
