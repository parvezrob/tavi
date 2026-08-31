import Foundation

protocol TerminalWebSocketTasking: AnyObject, Sendable {
    var response: URLResponse? { get }

    func resume()
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: TerminalWebSocketTasking {}

protocol TerminalMessageSending: Sendable {
    func send(_ message: TerminalClientMessage) async throws
}

protocol TerminalTransporting: TerminalMessageSending {
    func connect(configuration: TerminalConnectionConfiguration, resume: TerminalResumePoint?) async throws
    func receive() async -> TerminalTransportEvent
    func disconnect() async
}

actor TerminalWebSocketClient: TerminalTransporting {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let makeSocket: @Sendable (URLRequest) -> any TerminalWebSocketTasking

    private var negotiatedProtocolValidated = false
    private var socket: (any TerminalWebSocketTasking)?

    init(session: URLSession? = nil) {
        let resolved = session ?? Self.makeTerminalSession()
        makeSocket = { request in
            resolved.webSocketTask(with: request)
        }
    }

    // waitsForConnectivity would silently park a handshake on a dead path;
    // the controller owns retry timing, so failures must surface fast. The
    // request timeout is idle-based and stays above the heartbeat cadence.
    private static func makeTerminalSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    init(
        makeSocket: @escaping @Sendable (URLRequest) -> any TerminalWebSocketTasking
    ) {
        self.makeSocket = makeSocket
    }

    func connect(configuration: TerminalConnectionConfiguration, resume: TerminalResumePoint?) throws {
        guard socket == nil else {
            throw TerminalTransportError.alreadyConnected
        }

        var endpoint = configuration.endpoint
        if let resume,
           var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "stream", value: resume.stream))
            items.append(URLQueryItem(name: "resume", value: String(resume.offset)))
            components.queryItems = items
            endpoint = components.url ?? endpoint
        }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(configuration.credential)", forHTTPHeaderField: "Authorization")
        request.setValue(TerminalWireProtocol.name, forHTTPHeaderField: "Sec-WebSocket-Protocol")

        let socket = makeSocket(request)
        self.socket = socket
        negotiatedProtocolValidated = false
        socket.resume()
    }

    func receive() async -> TerminalTransportEvent {
        guard let activeSocket = socket else {
            return .disconnected
        }

        do {
            let frame = try await activeSocket.receive()
            guard socket === activeSocket else { return .disconnected }
            try validateNegotiatedProtocol(for: activeSocket)
            return .message(try decodeMessage(from: frame))
        } catch is CancellationError {
            finish(activeSocket, closeCode: .normalClosure)
            return .disconnected
        } catch let error as TerminalTransportError {
            finish(activeSocket, closeCode: .protocolError)
            return .failed(error)
        } catch is DecodingError {
            finish(activeSocket, closeCode: .protocolError)
            return .failed(.invalidFrame)
        } catch {
            let handshakeError = classifyHandshakeFailure(activeSocket.response)
            finish(activeSocket, closeCode: .goingAway)
            return handshakeError.map(TerminalTransportEvent.failed) ?? .disconnected
        }
    }

    func send(_ message: TerminalClientMessage) async throws {
        guard let socket else {
            throw TerminalTransportError.notConnected
        }
        let data = try encoder.encode(message)
        guard data.count <= TerminalWireProtocol.maximumFrameBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw TerminalTransportError.oversizedFrame
        }
        do {
            try await socket.send(.string(text))
        } catch {
            throw TerminalTransportError.deliveryUncertain
        }
    }

    func disconnect() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        negotiatedProtocolValidated = false
    }

    private func validateNegotiatedProtocol(
        for activeSocket: any TerminalWebSocketTasking
    ) throws {
        guard !negotiatedProtocolValidated else { return }
        guard let response = activeSocket.response as? HTTPURLResponse,
              response.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == TerminalWireProtocol.name else {
            throw TerminalTransportError.protocolMismatch
        }
        negotiatedProtocolValidated = true
    }

    private func classifyHandshakeFailure(_ response: URLResponse?) -> TerminalTransportError? {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        switch status {
        case 401:
            return .authenticationRejected
        case 404:
            return .agentNotFound
        case 400...499:
            return .handshakeRejected(status: status)
        default:
            return nil
        }
    }

    private func finish(
        _ activeSocket: any TerminalWebSocketTasking,
        closeCode: URLSessionWebSocketTask.CloseCode
    ) {
        guard socket === activeSocket else { return }
        activeSocket.cancel(with: closeCode, reason: nil)
        socket = nil
        negotiatedProtocolValidated = false
    }

    private func decodeMessage(
        from frame: URLSessionWebSocketTask.Message
    ) throws -> TerminalServerMessage {
        switch frame {
        case let .data(payload):
            return try parseOutputFrame(payload)
        case let .string(value):
            let data = Data(value.utf8)
            guard data.count <= TerminalWireProtocol.maximumFrameBytes else {
                throw TerminalTransportError.oversizedFrame
            }
            return try decoder.decode(TerminalServerMessage.self, from: data)
        @unknown default:
            throw TerminalTransportError.invalidFrame
        }
    }

    private func parseOutputFrame(_ payload: Data) throws -> TerminalServerMessage {
        guard payload.count <= TerminalWireProtocol.maximumFrameBytes else {
            throw TerminalTransportError.oversizedFrame
        }
        guard payload.count >= TerminalWireProtocol.outputFrameHeaderBytes,
              payload.first == TerminalWireProtocol.outputFrameType else {
            throw TerminalTransportError.invalidFrame
        }
        var offset: UInt64 = 0
        let headerStart = payload.index(payload.startIndex, offsetBy: 1)
        let headerEnd = payload.index(payload.startIndex, offsetBy: TerminalWireProtocol.outputFrameHeaderBytes)
        for byte in payload[headerStart..<headerEnd] {
            offset = offset << 8 | UInt64(byte)
        }
        return .outputChunk(offset: offset, data: Data(payload[headerEnd...]))
    }
}
