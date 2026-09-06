import Foundation
@testable import Tavi
import Testing

// What a socket failure is allowed to say in a log (#107). The address a
// connection failed against is the tailnet name of the owner's computer, so
// the record carries a tag this app chose and a protocol number — never a
// piece of the error itself.
struct SocketFailureTests {
    @Test(arguments: zip(
        [
            NetworkWebSocketTask.Failure.handshakeRejected,
            .cancelled,
            .notConnected,
            .connectionFailed("Connection refused by mac.tailnet.ts.net:443"),
            .closed(code: nil, reason: nil),
        ],
        [
            SocketFailure.Tag.handshakeRejected,
            .cancelled,
            .notConnected,
            .connectionFailed,
            .closed,
        ]
    ))
    func everySocketFailureHasItsOwnTag(
        failure: NetworkWebSocketTask.Failure,
        tag: SocketFailure.Tag
    ) {
        #expect(SocketFailure(failure).tag == tag)
    }

    // The one case that carries text drops it: a tag is a constant, so no
    // address can reach the log through it.
    @Test func aConnectionFailureKeepsNoneOfItsMessage() {
        let address = "mac.tailnet.ts.net"
        let failure = SocketFailure(NetworkWebSocketTask.Failure.connectionFailed("refused by \(address)"))
        #expect(failure.tag == .connectionFailed)
        #expect(failure.tag.rawValue.contains(address) == false)
        #expect(failure.code == 0)
    }

    // The peer's close code is a protocol number and is worth keeping. Its
    // reason is peer-supplied text: the terminal client reads it to
    // recognize a takeover (#108), and the record maps it to nothing.
    @Test func aPeersCloseCodeSurvivesAndItsReasonChangesNothing() {
        #expect(SocketFailure(NetworkWebSocketTask.Failure.closed(code: 1_006, reason: nil)).code == 1_006)
        #expect(SocketFailure(NetworkWebSocketTask.Failure.closed(code: nil, reason: nil)).code == 0)
        #expect(
            SocketFailure(NetworkWebSocketTask.Failure.closed(code: 1_000, reason: "superseded"))
                == SocketFailure(NetworkWebSocketTask.Failure.closed(code: 1_000, reason: nil))
        )
    }

    // A frame the app cannot read is its own reason, not "unknown": the
    // decode path throws beside the socket's own failures.
    @Test func aDecodeFailureIsNamed() throws {
        let error = try #require(decodeFailure(of: #"{"type":1}"#))
        #expect(SocketFailure(error).tag == .decodeFailed)
    }

    @Test func aURLErrorKeepsItsCode() {
        let failure = SocketFailure(URLError(.networkConnectionLost))
        #expect(failure.tag == .urlError)
        #expect(failure.code == URLError.networkConnectionLost.rawValue)
    }

    @Test func anythingElseIsUnknownRatherThanDescribed() {
        struct Unnamed: Error, LocalizedError {
            var errorDescription: String? { "wss://mac.tailnet.ts.net/api/agents/pane-1" }
        }
        let failure = SocketFailure(Unnamed())
        #expect(failure.tag == .unknown)
        #expect(failure.code == 0)
    }

    private func decodeFailure(of json: String) -> (any Error)? {
        do {
            _ = try JSONDecoder().decode(TerminalServerMessage.self, from: Data(json.utf8))
            return nil
        } catch {
            return error
        }
    }
}
