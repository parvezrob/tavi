import Foundation
import Observation

// Every computer this phone is paired with, each with its own live mirror
// (#50). One `AgentDirectory` per host runs concurrently, so a Mac that is
// asleep never hides the agents on the Linux box beside it. This is the
// only place that writes the paired-host list or a host's credential.
@MainActor
@Observable
final class HostFleet {
    private(set) var hosts: [PairedHost] = []
    private(set) var directories: [String: AgentDirectory] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isConfigured: Bool { !hosts.isEmpty }

    struct Entry: Identifiable {
        let host: PairedHost
        let directory: AgentDirectory
        var id: String { host.id }
    }

    // Hosts in pairing order with their directories — the home's spine.
    var entries: [Entry] {
        hosts.compactMap { host in
            directories[host.id].map { Entry(host: host, directory: $0) }
        }
    }

    func host(for id: String) -> PairedHost? {
        hosts.first { $0.id == id }
    }

    func directory(for hostId: String) -> AgentDirectory? {
        directories[hostId]
    }

    func credential(for hostId: String) -> String {
        HostCredentialStore.load(hostId: hostId)
    }

    // Reads the list and starts a mirror per host. Safe to call again: the
    // directories are rebuilt from what is on disk.
    func load() {
        PairedHostRegistry.migrateLegacy(in: defaults)
        stopAll()
        hosts = PairedHostRegistry.load(from: defaults)
        directories = [:]
        for host in hosts {
            directories[host.id] = makeDirectory(for: host)
        }
    }

    // Adds a computer, or replaces the one with the same id (pairing the
    // same Mac twice keeps a single entry in its original place).
    func add(_ host: PairedHost, credential: String) {
        HostCredentialStore.save(credential, hostId: host.id)
        hosts = PairedHostRegistry.upsert(host, in: defaults)
        directories[host.id]?.stop()
        directories[host.id] = makeDirectory(for: host)
    }

    // Forgets one computer: credential out of the Keychain, record out of
    // the list, mirror stopped. The others keep running.
    func remove(hostId: String) {
        directories[hostId]?.stop()
        directories[hostId] = nil
        HostCredentialStore.delete(hostId: hostId)
        hosts = PairedHostRegistry.remove(id: hostId, from: defaults)
    }

    // Back to "no paired computers".
    func removeAll() {
        stopAll()
        for host in hosts { HostCredentialStore.delete(hostId: host.id) }
        HostCredentialStore.deleteAll()
        PairedHostRegistry.clear(from: defaults)
        hosts = []
        directories = [:]
    }

    func start() {
        for directory in directories.values { directory.start() }
    }

    func stop() {
        stopAll()
    }

    private func stopAll() {
        for directory in directories.values { directory.stop() }
    }

    private func makeDirectory(for host: PairedHost) -> AgentDirectory {
        let directory = AgentDirectory()
        directory.configure(hostId: host.id, hostText: host.address, credential: credential(for: host.id))
        return directory
    }
}
