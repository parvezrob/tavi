import Foundation

// What the path monitor is worth to a connection, once the repeats are gone:
// the link is down, it came back, or it moved to another interface. The
// owner of a connection acts on these; nobody else has to know that the
// monitor repeats the same snapshot on every unrelated change (#111).
@MainActor
final class NetworkPathWatch {
    enum Event: Equatable {
        case lost
        case restored(from: NetworkPathSnapshot, to: NetworkPathSnapshot)
        case changed(from: NetworkPathSnapshot, to: NetworkPathSnapshot)
    }

    // The path as it stands, for a caller that has to ask rather than wait.
    private(set) var current: NetworkPathSnapshot?

    private let observer: any NetworkPathObserving
    private var task: Task<Void, Never>?

    init(observer: any NetworkPathObserving = NetworkPathObserver()) {
        self.observer = observer
    }

    func start(onEvent: @escaping @MainActor (Event) -> Void) {
        guard task == nil else { return }
        let observer = observer
        task = Task { [weak self] in
            for await snapshot in observer.updates() {
                guard let self, !Task.isCancelled else { return }
                if let event = record(snapshot) { onEvent(event) }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        current = nil
    }

    private func record(_ snapshot: NetworkPathSnapshot) -> Event? {
        let previous = current
        current = snapshot
        guard previous != snapshot else { return nil }
        // An unsatisfied path is worth reporting before there is a baseline:
        // a connection that starts with no network must not wait for one.
        if !snapshot.isSatisfied { return .lost }
        // The first satisfied snapshot is only the baseline; churning a
        // healthy startup connection would add latency for nothing.
        guard let previous else { return nil }
        return previous.isSatisfied
            ? .changed(from: previous, to: snapshot)
            : .restored(from: previous, to: snapshot)
    }
}
