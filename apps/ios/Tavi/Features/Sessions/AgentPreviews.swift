import Foundation
import Observation

// The terminal excerpts behind one computer's home cards (#26): one GET per
// previewed pane, coalesced so a flapping snapshot costs one round.
@MainActor
@Observable
final class AgentPreviews {
    // Safe, sanitized terminal excerpts keyed by pane id.
    private(set) var previews: [String: String] = [:]

    // Long enough that a burst of snapshots costs one round of GETs.
    private static let debounce: Duration = .seconds(2)

    private var routes: HostRoutes?
    private var task: Task<Void, Never>?

    func configure(routes: HostRoutes) {
        cancel()
        self.routes = routes
        previews = [:]
    }

    // Fetched only for the agents the home shows in full cards — needs-you
    // and active. Every one of those is working or blocked and leads with
    // its screen (PRD §7.3), so what a flapping snapshot costs is bounded by
    // the debounce rather than by skipping panes.
    func refresh(for agents: [AgentSummary]) {
        task?.cancel()
        let paneIds = agents.filter { $0.homeSection != .recent }.map(\.id)
        guard !paneIds.isEmpty, routes?.isConfigured == true else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.fetch(paneIds: paneIds)
        }
    }

    // A pane the host no longer reports keeps no excerpt.
    func prune(keeping paneIds: Set<String>) {
        previews = previews.filter { paneIds.contains($0.key) }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func fetch(paneIds: [String]) async {
        guard let routes else { return }
        var fetched: [String: String] = [:]
        for paneId in paneIds {
            if let raw = await routes.preview(paneId: paneId) {
                fetched[paneId] = AgentPreviewFormatter.sanitize(raw)
            }
            // A newer round cancelled this one: commit what already arrived
            // rather than let a busy host starve the cards.
            if Task.isCancelled { break }
        }
        guard !fetched.isEmpty else { return }
        // One write for the whole round: each one invalidates the home.
        previews.merge(fetched) { _, new in new }
    }
}
