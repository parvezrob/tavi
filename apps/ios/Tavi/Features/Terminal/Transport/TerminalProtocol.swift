import Foundation

enum TerminalWireProtocol {
    static let name = "tavi.v2"
    static let maximumFrameBytes = 64 * 1_024
    // v2 binary output frame: [0x01][8-byte big-endian start offset][bytes].
    static let outputFrameType: UInt8 = 0x01
    static let outputFrameHeaderBytes = 9
    // The takeover outcome (#108). A host that predates the code sends this
    // sentence alone, so the exact string stays part of the contract.
    static let takeoverMessage = "Another connection took over this terminal."
    static var supersededCloseReason: String { TerminalErrorCode.superseded.rawValue }
}

// The machine-readable half of a server `error` frame. Additive: an
// unrecognized value decodes to nil and the frame keeps its ordinary
// meaning, so a newer host cannot make this client fail on a word it has
// never heard.
enum TerminalErrorCode: String, Sendable {
    case superseded
}

// Where in the session's output byte stream this client wants to continue.
// stream is the host attachment's epoch token; offsets from a different
// epoch are meaningless and the host answers with a fresh attach.
struct TerminalResumePoint: Sendable, Equatable {
    let stream: String
    private(set) var offset: UInt64

    // The host may trim everything behind the offset, so it moves only for
    // bytes the client has taken responsibility for (#108).
    mutating func advance(to nextOffset: UInt64) {
        offset = nextOffset
    }
}

// A terminal is always one herdr agent pane on one host (#53).
struct TerminalConnectionConfiguration: Sendable {
    let endpoint: URL
    let credential: String
    let paneID: String

    init(host: HostEndpoint, paneID: String, credential: String) throws {
        guard !credential.isEmpty else {
            throw TerminalTransportError.missingCredential
        }
        self.endpoint = try host.agentTerminalURL(forPane: paneID)
        self.credential = credential
        self.paneID = paneID
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
    case error(message: String, code: TerminalErrorCode?)

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
            // `code` shares its key with the numeric exit status, which the
            // exit branch decodes instead; here anything that is not a
            // string this build knows is simply absent.
            self = .error(
                message: try container.decode(String.self, forKey: .message),
                code: TerminalErrorCode(rawValue: (try? container.decode(String.self, forKey: .code)) ?? "")
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported terminal message type."
            )
        }
    }
}

extension TerminalServerMessage {
    // The two takeover signals a frame can carry: the machine code, and —
    // from a host older than the code — the exact sentence on its own. Any
    // other code is additive and leaves the frame an ordinary error (#108).
    var isTakeoverNotice: Bool {
        guard case let .error(message, code) = self else { return false }
        return code == .superseded || message == TerminalWireProtocol.takeoverMessage
    }
}

enum TerminalTransportEvent: Sendable, Equatable {
    case message(TerminalServerMessage)
    case disconnected
    // The socket closed 1000 with reason `superseded`: another connection
    // owns the attachment now. Not a failure — the durable agent is still
    // running on the host (#108).
    case takenOver
    case failed(TerminalTransportError)
}

enum TerminalTransportError: Error, LocalizedError, Sendable, Equatable {
    case agentNotFound
    case alreadyConnected
    case authenticationRejected
    case deliveryUncertain
    case invalidFrame
    case missingCredential
    case notConnected
    case oversizedFrame
    case protocolMismatch

    var errorDescription: String? {
        switch self {
        case .agentNotFound:
            "That agent pane no longer exists on the host."
        case .alreadyConnected:
            "A terminal connection is already active."
        case .authenticationRejected:
            "The host rejected this access token. Reconnect with the current token."
        case .deliveryUncertain:
            "Input delivery is uncertain. Tavi did not replay it."
        case .invalidFrame:
            "The host sent an invalid terminal message."
        case .missingCredential:
            "Enter the host access token."
        case .notConnected:
            "The terminal is not connected."
        case .oversizedFrame:
            "The terminal message exceeded the safety limit."
        case .protocolMismatch:
            "The host does not support Tavi's terminal protocol version."
        }
    }

    var isPermanentConnectionFailure: Bool {
        switch self {
        case .agentNotFound, .authenticationRejected,
             .invalidFrame, .oversizedFrame, .protocolMismatch:
            true
        case .alreadyConnected, .deliveryUncertain, .missingCredential, .notConnected:
            false
        }
    }
}
