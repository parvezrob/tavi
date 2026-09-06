import Foundation
@testable import Tavi
import Testing

struct TerminalProtocolTests {
    @Test
    func decodesEveryValidServerFixture() throws {
        let fixture = try loadFixture()
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        for value in fixture.serverValid {
            let data = try encoder.encode(value)
            _ = try decoder.decode(TerminalServerMessage.self, from: data)
        }
    }

    @Test
    func rejectsEveryMalformedServerFixture() throws {
        let fixture = try loadFixture()
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        for value in fixture.serverInvalid {
            let data = try encoder.encode(value)
            #expect(throws: (any Error).self) {
                try decoder.decode(TerminalServerMessage.self, from: data)
            }
        }
    }

    // The ownership code is additive (#108): both takeover frames in the
    // shared fixture decode to the same outcome, and a code from a newer
    // host decodes to none at all rather than throwing.
    @Test
    func decodesTheOwnershipCodeAndToleratesUnknownOnes() throws {
        let decoder = JSONDecoder()
        let coded = #"{"type":"error","message":"Another connection took over this terminal.","code":"superseded"}"#
        let legacy = #"{"type":"error","message":"Another connection took over this terminal."}"#
        let unknown = #"{"type":"error","message":"Something new happened.","code":"quarantined"}"#
        let numeric = #"{"type":"error","message":"Something new happened.","code":7}"#

        #expect(
            try decoder.decode(TerminalServerMessage.self, from: Data(coded.utf8))
                == .error(message: TerminalWireProtocol.takeoverMessage, code: .superseded)
        )
        #expect(
            try decoder.decode(TerminalServerMessage.self, from: Data(legacy.utf8))
                == .error(message: TerminalWireProtocol.takeoverMessage, code: nil)
        )
        #expect(
            try decoder.decode(TerminalServerMessage.self, from: Data(unknown.utf8))
                == .error(message: "Something new happened.", code: nil)
        )
        #expect(
            try decoder.decode(TerminalServerMessage.self, from: Data(numeric.utf8))
                == .error(message: "Something new happened.", code: nil)
        )
        // exit.code stays the numeric status it has always been.
        #expect(
            try decoder.decode(TerminalServerMessage.self, from: Data(#"{"type":"exit","code":137}"#.utf8))
                == .exit(code: 137, signal: nil)
        )
    }

    @Test
    func encodesResizeAndHeartbeatWithStableFieldNames() throws {
        let encoder = JSONEncoder()

        let resize = try #require(
            String(data: encoder.encode(TerminalClientMessage.resize(columns: 90, rows: 28)), encoding: .utf8)
        )
        let ping = try #require(
            String(data: encoder.encode(TerminalClientMessage.ping(identifier: "heartbeat-1")), encoding: .utf8)
        )

        #expect(resize.contains("\"type\":\"resize\""))
        #expect(resize.contains("\"cols\":90"))
        #expect(resize.contains("\"rows\":28"))
        #expect(ping.contains("\"type\":\"ping\""))
        #expect(ping.contains("\"id\":\"heartbeat-1\""))
    }

    private func loadFixture() throws -> TerminalFixture {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            root.deleteLastPathComponent()
        }
        let fixtureURL = root
            .appending(path: "protocol/fixtures/terminal-v1/messages.json")
        return try JSONDecoder().decode(TerminalFixture.self, from: Data(contentsOf: fixtureURL))
    }
}

private struct TerminalFixture: Decodable {
    let serverValid: [JSONValue]
    let serverInvalid: [JSONValue]
}

private enum JSONValue: Codable, Sendable {
    case array([JSONValue])
    case boolean(Bool)
    case null
    case number(Double)
    case object([String: JSONValue])
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .array(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case .null: try container.encodeNil()
        case let .number(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        }
    }
}
