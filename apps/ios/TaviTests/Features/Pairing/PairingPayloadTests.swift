import Foundation
import Testing
@testable import Tavi

struct PairingPayloadTests {
    private let valid = "tavi://pair?u=https://studio-mac.tail1234.ts.net&s=abc_DEF-123&f=8F2A%2019C4%20%C2%B7%207B10%20D6E9&n=studio-mac"

    @Test
    func decodesTheCodeTheHostPrints() throws {
        let payload = try PairingPayload.decode("  \(valid)\n")

        #expect(payload.endpoint.baseURL.absoluteString == "https://studio-mac.tail1234.ts.net")
        #expect(payload.secret == "abc_DEF-123")
        #expect(payload.fingerprint == "8F2A 19C4 · 7B10 D6E9")
        #expect(payload.hostName == "studio-mac")
    }

    // The exact string a pre-fix host printed (owner screenshot): spaces as "+".
    @Test
    func acceptsPlusEncodedSpacesFromOlderHosts() throws {
        let code = "tavi://pair?u=https%3A%2F%2Fparvezs-macbook-air.tail4c71f5.ts.net&s=ishIShUAJxIhmHCbVgItGw&f=99F5+7AF0+%C2%B7+E678+C534&n=Parvezs-MacBook-Air"
        let payload = try PairingPayload.decode(code)
        #expect(payload.fingerprint == "99F5 7AF0 · E678 C534")
        #expect(payload.hostName == "Parvezs-MacBook-Air")
        #expect(payload.secret == "ishIShUAJxIhmHCbVgItGw")
    }

    @Test
    func fallsBackToTheHostnameWhenNoNameIsGiven() throws {
        let payload = try PairingPayload.decode("tavi://pair?u=https://studio-mac.tail1234.ts.net&s=x&f=y")
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
            try PairingPayload.decode("tavi://pair?u=https://a.ts.net&s=&f=z")
        }
    }

    @Test
    func aPairingCodeCannotRelaxTheHostRules() {
        // Plain HTTP or a non-Tailscale host is refused exactly as it would
        // be when typed by hand.
        #expect(throws: PairingPayload.DecodeError.self) {
            try PairingPayload.decode("tavi://pair?u=http://studio-mac.tail1234.ts.net&s=x&f=y")
        }
        #expect(throws: PairingPayload.DecodeError.self) {
            try PairingPayload.decode("tavi://pair?u=https://evil.example.com&s=x&f=y")
        }
    }

    @Test
    func pairedHostRecordRoundTripsThroughDefaults() {
        let defaults = UserDefaults(suiteName: "tavi.tests.\(UUID().uuidString)")!
        let record = PairedHostRecord(
            hostName: "studio-mac",
            fingerprint: "8F2A 19C4 · 7B10 D6E9",
            deviceId: "abc123",
            deviceName: "Parvez's iPhone",
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(PairedHostRecord.load(from: defaults) == nil)
        record.save(to: defaults)
        #expect(PairedHostRecord.load(from: defaults) == record)
        PairedHostRecord.clear(from: defaults)
        #expect(PairedHostRecord.load(from: defaults) == nil)
    }
}
