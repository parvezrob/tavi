import Foundation

// One computer this phone is paired with (#50). The phone keeps a list of
// these; the credential for each lives in the Keychain under the host's id
// (`HostCredentialStore`), never here. Nothing in this record is secret, so
// it sits in UserDefaults next to the app's other preferences.
struct PairedHost: Codable, Equatable, Hashable, Identifiable {
    // Stable identity for the computer: its host fingerprint, which
    // survives re-pairing. A host typed into the DEBUG form has no
    // fingerprint and is keyed by its address instead. Re-pairing the same
    // computer therefore replaces its record rather than adding a twin.
    let id: String
    let hostName: String
    // The https origin, as HostEndpoint validates it.
    let address: String
    let fingerprint: String?
    let deviceId: String?
    let deviceName: String?
    let pairedAt: Date
    // Your own name for this computer (Orca lets you rename a host; two
    // "ubuntu" boxes need it). nil until set; absent from older records.
    var alias: String? = nil

    static func paired(endpoint: HostEndpoint, grant: HostPairing.Grant, at date: Date = Date()) -> PairedHost {
        PairedHost(
            id: grant.fingerprint,
            hostName: grant.hostName,
            address: endpoint.baseURL.absoluteString,
            fingerprint: grant.fingerprint,
            deviceId: grant.deviceId,
            deviceName: grant.deviceName,
            pairedAt: date
        )
    }

    // A host entered by address (development form, TAVI_DEV_HOST): no
    // pairing grant, so the address is all the identity there is.
    static func typed(address: String, at date: Date = Date()) -> PairedHost {
        PairedHost(
            id: "address:" + address.lowercased(),
            hostName: HomeGrouping.computerName(pairedName: nil, hostText: address),
            address: address,
            fingerprint: nil,
            deviceId: nil,
            deviceName: nil,
            pairedAt: date
        )
    }

    var endpoint: HostEndpoint? {
        URL(string: address).flatMap { try? HostEndpoint(baseURL: $0) }
    }

    // What the phone calls this computer: your alias if you set one, else
    // the short form of the name it gave when pairing, else its address
    // label. Never empty — it is a landmark on every screen.
    var displayName: String {
        if let alias = alias?.trimmingCharacters(in: .whitespaces), !alias.isEmpty { return alias }
        return Self.shortName(HomeGrouping.computerName(pairedName: hostName, hostText: address))
    }

    // The name the computer reported, as it reported it.
    var reportedName: String {
        HomeGrouping.computerName(pairedName: hostName, hostText: address)
    }

    // "Parvezs-MacBook-Air" → "MacBook Air": a leading possessive label
    // ("<Name>s-") followed by at least two more labels is dropped and the
    // rest is spaced. "robin-PC", "ubuntu", "studio-mac" stay as they are.
    static func shortName(_ name: String) -> String {
        let parts = name.split(separator: "-").map(String.init)
        guard parts.count >= 3, let first = parts.first,
              first.count >= 3, first.lowercased().hasSuffix("s"),
              first.allSatisfy(\.isLetter) else { return name }
        return parts.dropFirst().joined(separator: " ")
    }

    func renamed(_ alias: String?) -> PairedHost {
        var host = self
        let trimmed = alias?.trimmingCharacters(in: .whitespaces) ?? ""
        host.alias = trimmed.isEmpty ? nil : trimmed
        return host
    }
}

// The paired-host list on disk, in pairing order. Adding the same computer
// again (same id) replaces it in place so it keeps its position.
enum PairedHostRegistry {
    static let storageKey = "tavi.pairedHosts"

    // Pre-#50 keys: one host record and one address.
    static let legacyRecordKey = "tavi.pairedHost"
    static let legacyAddressKey = "tavi.dev.host"

    static func load(from defaults: UserDefaults = .standard) -> [PairedHost] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([PairedHost].self, from: data)) ?? []
    }

    static func save(_ hosts: [PairedHost], to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(hosts) {
            defaults.set(data, forKey: storageKey)
        }
    }

    @discardableResult
    static func upsert(_ host: PairedHost, in defaults: UserDefaults = .standard) -> [PairedHost] {
        var hosts = load(from: defaults)
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        save(hosts, to: defaults)
        return hosts
    }

    @discardableResult
    static func remove(id: String, from defaults: UserDefaults = .standard) -> [PairedHost] {
        let hosts = load(from: defaults).filter { $0.id != id }
        save(hosts, to: defaults)
        return hosts
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    // A phone updated from the one-host app (#46) had one address, one
    // pairing record and one Keychain credential. They become the first
    // entry of the list, and the credential moves under the host's id.
    // The legacy keys are removed only once the list is written and the
    // credential has moved; if the Keychain is not available yet (first
    // launch before unlock) nothing is touched and the next launch retries.
    static func migrateLegacy(
        in defaults: UserDefaults = .standard,
        moveCredential: (_ hostId: String) -> Bool = { HostCredentialStore.migrateLegacyCredential(toHostId: $0) }
    ) {
        func forgetLegacyKeys() {
            defaults.removeObject(forKey: legacyRecordKey)
            defaults.removeObject(forKey: legacyAddressKey)
        }
        guard defaults.data(forKey: storageKey) == nil else {
            forgetLegacyKeys()
            return
        }
        let address = defaults.string(forKey: legacyAddressKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !address.isEmpty else {
            forgetLegacyKeys()
            return
        }

        let record = defaults.data(forKey: legacyRecordKey).flatMap { try? JSONDecoder().decode(LegacyRecord.self, from: $0) }
        let host: PairedHost
        if let record {
            host = PairedHost(
                id: record.fingerprint,
                hostName: record.hostName,
                address: address,
                fingerprint: record.fingerprint,
                deviceId: record.deviceId,
                deviceName: record.deviceName,
                pairedAt: record.pairedAt
            )
        } else {
            host = .typed(address: address)
        }
        guard moveCredential(host.id) else { return }
        save([host], to: defaults)
        forgetLegacyKeys()
    }

    private struct LegacyRecord: Decodable {
        let hostName: String
        let fingerprint: String
        let deviceId: String
        let deviceName: String
        let pairedAt: Date
    }
}
