import Foundation
import Testing
@testable import Mocha

struct PairingPayloadTests {
    private let valid = "mocha://pair?u=https://studio-mac.tail1234.ts.net&s=abc_DEF-123&f=8F2A%2019C4%20%C2%B7%207B10%20D6E9&n=studio-mac"

    @Test
    func decodesTheCodeTheHostPrints() throws {
        let payload = try PairingPayload.decode("  \(valid)\n")

        #expect(payload.endpoint.baseURL.absoluteString == "https://studio-mac.tail1234.ts.net")
        #expect(payload.secret == "abc_DEF-123")
        #expect(payload.fingerprint == "8F2A 19C4 · 7B10 D6E9")
        #expect(payload.hostName == "studio-mac")
    }

    @Test
    func fallsBackToTheHostnameWhenNoNameIsGiven() throws {
        let payload = try PairingPayload.decode("mocha://pair?u=https://studio-mac.tail1234.ts.net&s=x&f=y")
        #expect(payload.hostName == "studio-mac.tail1234.ts.net")
    }

    @Test
    func refusesAnythingThatIsNotAPairingCode() {
        #expect(throws: PairingPayload.DecodeError.notAPairingCode) {
            try PairingPayload.decode("https://example.com/pair?u=x&s=y&f=z")
        }
        #expect(throws: PairingPayload.DecodeError.notAPairingCode) {
            try PairingPayload.decode("hello")
        }
        #expect(throws: PairingPayload.DecodeError.incomplete) {
            try PairingPayload.decode("mocha://pair?u=https://a.ts.net&s=&f=z")
        }
    }

    @Test
    func aPairingCodeCannotRelaxTheHostRules() {
        // Plain HTTP or a non-Tailscale host is refused exactly as it would
        // be when typed by hand.
        #expect(throws: PairingPayload.DecodeError.self) {
            try PairingPayload.decode("mocha://pair?u=http://studio-mac.tail1234.ts.net&s=x&f=y")
        }
        #expect(throws: PairingPayload.DecodeError.self) {
            try PairingPayload.decode("mocha://pair?u=https://evil.example.com&s=x&f=y")
        }
    }
}
