import Foundation
import Network

struct NetworkPathSnapshot: Sendable, Equatable {
    let isSatisfied: Bool
    let interfaceIdentity: String
}

protocol NetworkPathObserving: Sendable {
    func updates() -> AsyncStream<NetworkPathSnapshot>
}

// A socket that was healthy on Wi-Fi is dead-on-arrival after a flip to
// cellular, but nothing on the connection reports that until a heartbeat
// times out. Path updates let the controller reconnect the moment the
// network actually changes instead of waiting to notice.
final class NetworkPathObserver: NetworkPathObserving {
    func updates() -> AsyncStream<NetworkPathSnapshot> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(
                    NetworkPathSnapshot(
                        isSatisfied: path.status == .satisfied,
                        interfaceIdentity: path.availableInterfaces.first?.name ?? "none"
                    )
                )
            }
            monitor.start(queue: DispatchQueue(label: "com.farfield.tavi.network-path"))
            continuation.onTermination = { _ in
                monitor.cancel()
            }
        }
    }
}
