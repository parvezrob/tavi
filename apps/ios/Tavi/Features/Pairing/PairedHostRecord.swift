import Foundation

// What the phone remembers about its pairing (#46), so "This iPhone" can
// show who it is to the host and where to be revoked. None of this is a
// secret — the credential lives in the Keychain — so it sits in AppStorage
// next to the host address.
struct PairedHostRecord: Codable, Equatable {
    let hostName: String
    let fingerprint: String
    let deviceId: String
    let deviceName: String
    let pairedAt: Date

    static let storageKey = "tavi.pairedHost"

    static func load(from defaults: UserDefaults = .standard) -> PairedHostRecord? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(PairedHostRecord.self, from: data)
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}
