import Foundation

// Why a socket ended, reduced to a fixed token and a number so the
// connection logs can name it (#107). Everything here is either a constant
// this file chose or a protocol code: no error message survives, because
// NWError's description carries the address the connection failed against,
// and that is the tailnet name of the owner's computer.
struct SocketFailure: Sendable, Equatable {
    enum Tag: String, Sendable {
        case cancelled
        case closed
        case connectionFailed = "connection-failed"
        case decodeFailed = "decode-failed"
        case handshakeRejected = "handshake-rejected"
        case notConnected = "not-connected"
        case unknown
        case urlError = "url-error"
    }

    let tag: Tag
    // The peer's WebSocket close code, or the URLError code; 0 when the
    // failure carries neither.
    let code: Int

    init(_ error: any Error) {
        switch error {
        case is DecodingError:
            self.init(.decodeFailed)
        case is CancellationError:
            self.init(.cancelled)
        case let failure as NetworkWebSocketTask.Failure:
            switch failure {
            case .cancelled: self.init(.cancelled)
            // The reason is peer-supplied text and stays out of the record;
            // only the protocol number survives.
            case let .closed(code, _): self.init(.closed, code: Int(code ?? 0))
            case .connectionFailed: self.init(.connectionFailed)
            case .handshakeRejected: self.init(.handshakeRejected)
            case .notConnected: self.init(.notConnected)
            }
        case let urlError as URLError:
            self.init(.urlError, code: urlError.code.rawValue)
        default:
            self.init(.unknown)
        }
    }

    // Private so a failure can only be named by classifying a real error.
    private init(_ tag: Tag, code: Int = 0) {
        self.tag = tag
        self.code = code
    }
}
