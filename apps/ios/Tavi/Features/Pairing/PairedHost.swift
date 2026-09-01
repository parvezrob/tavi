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

    // What the home calls this computer: the name it gave when pairing,
    // else its address label. Never empty — the header is a landmark.
    var displayName: String {
        HomeGrouping.computerName(pairedName: hostName, hostText: address)
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
    // Runs once: the legacy keys are removed whether or not they held
    // anything worth keeping.
    static func migrateLegacy(
        in defaults: UserDefaults = .standard,
        moveCredential: (_ hostId: String) -> Void = { HostCredentialStore.migrateLegacyCredential(toHostId: $0) }
    ) {
        defer {
            defaults.removeObject(forKey: legacyRecordKey)
            defaults.removeObject(forKey: legacyAddressKey)
        }
        guard defaults.data(forKey: storageKey) == nil else { return }
        let address = defaults.string(forKey: legacyAddressKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !address.isEmpty else { return }

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
        save([host], to: defaults)
        moveCredential(host.id)
    }

    private struct LegacyRecord: Decodable {
        let hostName: String
        let fingerprint: String
        let deviceId: String
        let deviceName: String
        let pairedAt: Date
    }
}
