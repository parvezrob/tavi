import Foundation

enum TerminalWireProtocol {
    static let name = "mocha.v2"
    static let maximumFrameBytes = 64 * 1_024
    // v2 binary output frame: [0x01][8-byte big-endian start offset][bytes].
    static let outputFrameType: UInt8 = 0x01
    static let outputFrameHeaderBytes = 9
}

// Where in the session's output byte stream this client wants to continue.
// stream is the host attachment's epoch token; offsets from a different
// epoch are meaningless and the host answers with a fresh attach.
struct TerminalResumePoint: Sendable, Equatable {
    let stream: String
    let offset: UInt64
}

struct TerminalConnectionConfiguration: Sendable {
    let endpoint: URL
    let credential: String

    init(host: HostEndpoint, sessionID: SessionIdentifier, credential: String) throws {
        guard !credential.isEmpty else {
            throw TerminalTransportError.missingCredential
        }
        self.endpoint = try host.terminalURL(for: sessionID)
        self.credential = credential
    }
}

enum TerminalClientMessage: Sendable, Equatable, Encodable {
    case input(String)
    case resize(columns: Int, rows: Int)
    case ping(identifier: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case data
        case cols
        case rows
        case id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .input(data):
            try container.encode("input", forKey: .type)
            try container.encode(data, forKey: .data)
        case let .resize(columns, rows):
            try container.encode("resize", forKey: .type)
            try container.encode(columns, forKey: .cols)
            try container.encode(rows, forKey: .rows)
        case let .ping(identifier):
            try container.encode("ping", forKey: .type)
            try container.encode(identifier, forKey: .id)
        }
    }
}

enum TerminalServerMessage: Sendable, Equatable, Decodable {
    case ready(stream: String?, offset: UInt64, resumed: Bool)
    case output(String)
    case outputChunk(offset: UInt64, data: Data)
    case pong(identifier: String)
    case exit(code: Int, signal: Int?)
    case error(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case data
        case code
        case signal
        case message
        case id
        case stream
        case offset
        case resumed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "ready":
            self = .ready(
                stream: try container.decodeIfPresent(String.self, forKey: .stream),
                offset: try container.decodeIfPresent(UInt64.self, forKey: .offset) ?? 0,
                resumed: try container.decodeIfPresent(Bool.self, forKey: .resumed) ?? false
            )
        case "output":
            self = .output(try container.decode(String.self, forKey: .data))
        case "pong":
            self = .pong(identifier: try container.decode(String.self, forKey: .id))
        case "exit":
            self = .exit(
                code: try container.decode(Int.self, forKey: .code),
                signal: try container.decodeIfPresent(Int.self, forKey: .signal)
            )
        case "error":
            self = .error(try container.decode(String.self, forKey: .message))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported terminal message type."
            )
        }
    }
}

enum TerminalTransportEvent: Sendable, Equatable {
    case message(TerminalServerMessage)
    case disconnected
    case failed(TerminalTransportError)
}

enum TerminalTransportError: Error, LocalizedError, Sendable, Equatable {
    case alreadyConnected
    case authenticationRejected
    case deliveryUncertain
    case handshakeRejected(status: Int)
    case invalidFrame
    case missingCredential
    case notConnected
    case oversizedFrame
    case protocolMismatch
    case sessionNotFound

    var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            "A terminal connection is already active."
        case .authenticationRejected:
            "The host rejected this access token. Reconnect with the current token."
        case .deliveryUncertain:
            "Input delivery is uncertain. Mocha did not replay it."
        case let .handshakeRejected(status):
            "The host rejected the terminal connection (HTTP \(status))."
        case .invalidFrame:
            "The host sent an invalid terminal message."
        case .missingCredential:
            "Enter the host access token."
        case .notConnected:
            "The terminal is not connected."
        case .oversizedFrame:
            "The terminal message exceeded the safety limit."
        case .protocolMismatch:
            "The host does not support Mocha's terminal protocol version."
        case .sessionNotFound:
            "That tmux session no longer exists on the host."
        }
    }

    var isPermanentConnectionFailure: Bool {
        switch self {
        case .authenticationRejected, .handshakeRejected, .invalidFrame,
             .oversizedFrame, .protocolMismatch, .sessionNotFound:
            true
        case .alreadyConnected, .deliveryUncertain, .missingCredential, .notConnected:
            false
        }
    }
}
