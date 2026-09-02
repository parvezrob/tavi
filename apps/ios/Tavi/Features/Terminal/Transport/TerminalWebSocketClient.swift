import Foundation

// One WebSocket connection. The production implementation is
// NetworkWebSocketTask (Network.framework, #70); the message and close-code
// vocabulary stays URLSession's because it is just two enums.
protocol TerminalWebSocketTasking: AnyObject, Sendable {
    // The subprotocol the host accepted; nil before the handshake completes.
    var negotiatedProtocol: String? { get }

    func resume()
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

// Network.framework does not surface the HTTP status of a rejected upgrade,
// so after one the client asks the host over plain HTTP whether the
// credential or the pane is the problem. Both are permanent; anything else
// (herdr down, host restarting) is a retry.
protocol TerminalHandshakeProbing: Sendable {
    func classify(_ configuration: TerminalConnectionConfiguration) async -> TerminalTransportError?
}

struct TerminalHandshakeProbe: TerminalHandshakeProbing {
    private struct AgentList: Decodable {
        struct Agent: Decodable {
            let id: String
        }
        let available: Bool?
        let agents: [Agent]?
    }

    // One pool for the whole app (#86); this client's budget rides on each request.
    private static var session: URLSession { HostSession.shared }

    func classify(_ configuration: TerminalConnectionConfiguration) async -> TerminalTransportError? {
        guard var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = "https"
        components.path = "/api/agents"
        components.queryItems = nil
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Bearer \(configuration.credential)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await Self.session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        if status == 401 { return .authenticationRejected }
        guard status == 200,
              let list = try? JSONDecoder().decode(AgentList.self, from: data),
              list.available ?? true,
              let agents = list.agents else { return nil }
        return agents.contains { $0.id == configuration.paneID } ? nil : .agentNotFound
    }
}

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
    private let handshakeProbe: any TerminalHandshakeProbing

    private var negotiatedProtocolValidated = false
    private var socket: (any TerminalWebSocketTasking)?
    private var configuration: TerminalConnectionConfiguration?

    init(
        makeSocket: @escaping @Sendable (URLRequest) -> any TerminalWebSocketTasking = { NetworkWebSocketTask(request: $0) },
        handshakeProbe: any TerminalHandshakeProbing = TerminalHandshakeProbe()
    ) {
        self.makeSocket = makeSocket
        self.handshakeProbe = handshakeProbe
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
        // The handshake budget; the controller's connect deadline is shorter
        // and cycles a silent attempt first.
        request.timeoutInterval = 10
        request.setValue("Bearer \(configuration.credential)", forHTTPHeaderField: "Authorization")
        request.setValue(TerminalWireProtocol.name, forHTTPHeaderField: "Sec-WebSocket-Protocol")

        let socket = makeSocket(request)
        self.socket = socket
        self.configuration = configuration
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
        } catch NetworkWebSocketTask.Failure.handshakeRejected {
            let configuration = self.configuration
            finish(activeSocket, closeCode: .goingAway)
            guard let configuration,
                  let classified = await handshakeProbe.classify(configuration) else { return .disconnected }
            return .failed(classified)
        } catch {
            finish(activeSocket, closeCode: .goingAway)
            return .disconnected
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
        guard activeSocket.negotiatedProtocol == TerminalWireProtocol.name else {
            throw TerminalTransportError.protocolMismatch
        }
        negotiatedProtocolValidated = true
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
