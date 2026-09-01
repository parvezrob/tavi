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
    func pairedHostsRoundTripAndUpsertByIdentity() {
        let defaults = UserDefaults(suiteName: "tavi.tests.\(UUID().uuidString)")!
        let mac = PairedHost(
            id: "8F2A 19C4 · 7B10 D6E9",
            hostName: "studio-mac",
            address: "https://studio-mac.tail.ts.net",
            fingerprint: "8F2A 19C4 · 7B10 D6E9",
            deviceId: "abc123",
            deviceName: "Parvez's iPhone",
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let linux = PairedHost.typed(address: "https://ubuntu.tail.ts.net")

        #expect(PairedHostRegistry.load(from: defaults).isEmpty)
        PairedHostRegistry.upsert(mac, in: defaults)
        PairedHostRegistry.upsert(linux, in: defaults)
        #expect(PairedHostRegistry.load(from: defaults) == [mac, linux])

        // Pairing the same computer again replaces it in place.
        let repaired = PairedHost(
            id: mac.id,
            hostName: "studio-mac",
            address: mac.address,
            fingerprint: mac.fingerprint,
            deviceId: "def456",
            deviceName: "Parvez's iPhone",
            pairedAt: Date(timeIntervalSince1970: 1_700_009_000)
        )
        PairedHostRegistry.upsert(repaired, in: defaults)
        #expect(PairedHostRegistry.load(from: defaults) == [repaired, linux])

        PairedHostRegistry.remove(id: mac.id, from: defaults)
        #expect(PairedHostRegistry.load(from: defaults) == [linux])
        PairedHostRegistry.clear(from: defaults)
        #expect(PairedHostRegistry.load(from: defaults).isEmpty)
    }

    // "Parvezs-MacBook-Air" is how macOS names a machine; the possessive
    // is noise on a phone screen. Names without that shape are untouched.
    @Test
    func shortNamesDropThePossessiveLabelOnly() {
        #expect(PairedHost.shortName("Parvezs-MacBook-Air") == "MacBook Air")
        #expect(PairedHost.shortName("Johns-Mac-mini") == "Mac mini")
        #expect(PairedHost.shortName("robin-PC") == "robin-PC")
        #expect(PairedHost.shortName("ubuntu") == "ubuntu")
        #expect(PairedHost.shortName("studio-mac") == "studio-mac")
        #expect(PairedHost.shortName("dev-box-2") == "dev-box-2")
    }

    @Test
    func anAliasWinsAndAnEmptyAliasClears() {
        let host = PairedHost(
            id: "f", hostName: "Parvezs-MacBook-Air", address: "https://parvezs-macbook-air.tail.ts.net",
            fingerprint: "f", deviceId: nil, deviceName: nil, pairedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(host.displayName == "MacBook Air")
        #expect(host.reportedName == "Parvezs-MacBook-Air")
        #expect(host.renamed("Studio").displayName == "Studio")
        #expect(host.renamed("Studio").renamed("   ").displayName == "MacBook Air")
        #expect(host.renamed("Studio").renamed(nil).alias == nil)
    }

    // Records written before the alias existed still decode.
    @Test
    func recordsWithoutAnAliasStillDecode() throws {
        let json = """
        [{"id":"f","hostName":"studio-mac","address":"https://studio-mac.tail.ts.net","fingerprint":"f","deviceId":null,"deviceName":null,"pairedAt":0}]
        """
        let hosts = try JSONDecoder().decode([PairedHost].self, from: Data(json.utf8))
        #expect(hosts.first?.alias == nil)
        #expect(hosts.first?.displayName == "studio-mac")
    }

    @Test
    func typedHostsAreKeyedByAddressAndNamedByItsFirstLabel() {
        let host = PairedHost.typed(address: "https://Studio-Mac.tail.ts.net")
        #expect(host.id == "address:https://studio-mac.tail.ts.net")
        #expect(host.displayName == "Studio-Mac")
        #expect(host.fingerprint == nil)
        #expect(host.endpoint?.baseURL.host() == "Studio-Mac.tail.ts.net")
    }

    // A phone updated from the one-host app: its record, address and
    // credential become the first entry of the list, once.
    @Test
    func legacySingleHostMigratesIntoTheList() throws {
        let defaults = UserDefaults(suiteName: "tavi.tests.\(UUID().uuidString)")!
        let legacy: [String: Any] = [
            "hostName": "studio-mac",
            "fingerprint": "8F2A 19C4",
            "deviceId": "abc123",
            "deviceName": "Parvez's iPhone",
            "pairedAt": 1_700_000_000.0,
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: PairedHostRegistry.legacyRecordKey)
        defaults.set("https://studio-mac.tail.ts.net", forKey: PairedHostRegistry.legacyAddressKey)

        var moved: [String] = []
        PairedHostRegistry.migrateLegacy(in: defaults) { moved.append($0); return true }

        let hosts = PairedHostRegistry.load(from: defaults)
        #expect(hosts.count == 1)
        #expect(hosts.first?.id == "8F2A 19C4")
        #expect(hosts.first?.hostName == "studio-mac")
        #expect(hosts.first?.address == "https://studio-mac.tail.ts.net")
        #expect(hosts.first?.deviceName == "Parvez's iPhone")
        #expect(moved == ["8F2A 19C4"])
        #expect(defaults.object(forKey: PairedHostRegistry.legacyRecordKey) == nil)
        #expect(defaults.object(forKey: PairedHostRegistry.legacyAddressKey) == nil)

        // Running again is a no-op: the list is authoritative now.
        defaults.set("https://other.tail.ts.net", forKey: PairedHostRegistry.legacyAddressKey)
        PairedHostRegistry.migrateLegacy(in: defaults) { moved.append($0); return true }
        #expect(PairedHostRegistry.load(from: defaults) == hosts)
        #expect(moved == ["8F2A 19C4"])
    }

    @Test
    func legacyAddressWithoutARecordMigratesAsATypedHost() {
        let defaults = UserDefaults(suiteName: "tavi.tests.\(UUID().uuidString)")!
        defaults.set("https://dev-box.tail.ts.net", forKey: PairedHostRegistry.legacyAddressKey)
        var moved: [String] = []
        PairedHostRegistry.migrateLegacy(in: defaults) { moved.append($0); return true }
        let hosts = PairedHostRegistry.load(from: defaults)
        #expect(hosts.map(\.id) == ["address:https://dev-box.tail.ts.net"])
        #expect(moved == hosts.map(\.id))
    }

    // A Keychain that cannot be read yet (first launch before unlock)
    // leaves everything in place for the next launch — nothing is deleted
    // on the strength of a move that did not happen.
    @Test
    func migrationLeavesLegacyStateWhenTheCredentialCannotMove() {
        let defaults = UserDefaults(suiteName: "tavi.tests.\(UUID().uuidString)")!
        defaults.set("https://dev-box.tail.ts.net", forKey: PairedHostRegistry.legacyAddressKey)
        PairedHostRegistry.migrateLegacy(in: defaults) { _ in false }
        #expect(defaults.object(forKey: PairedHostRegistry.storageKey) == nil)
        #expect(defaults.string(forKey: PairedHostRegistry.legacyAddressKey) == "https://dev-box.tail.ts.net")
        PairedHostRegistry.migrateLegacy(in: defaults) { _ in true }
        #expect(PairedHostRegistry.load(from: defaults).count == 1)
        #expect(defaults.object(forKey: PairedHostRegistry.legacyAddressKey) == nil)
    }

    @Test
    func nothingToMigrateLeavesNoList() {
        let defaults = UserDefaults(suiteName: "tavi.tests.\(UUID().uuidString)")!
        var moved: [String] = []
        PairedHostRegistry.migrateLegacy(in: defaults) { moved.append($0); return true }
        #expect(defaults.object(forKey: PairedHostRegistry.storageKey) == nil)
        #expect(moved.isEmpty)
    }
}
