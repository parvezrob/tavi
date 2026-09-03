import Foundation

// What the home draws, kept beside SessionsView rather than in it: one
// grouping of the paired computers, the chip filter applied to it, and the
// memo that keeps both from running on a redraw that changed neither.

// A folder on a computer: two computers can hold the same path, so the
// list identity is both.
struct HomeProjectItem: Identifiable {
    let computer: HomeComputer
    let project: HomeProject
    var id: String { "\(computer.id)|\(project.id)" }
}

// Everything the home draws, in the shape it draws it: the grouping, and
// the chip filter applied to it once.
struct HomeSections {
    let computers: [HomeComputer]
    let shown: [HomeComputer]
    let severalShown: Bool
    let needsYou: [AgentSummary]
    let projects: [HomeProjectItem]
}

// The last set of sections and the input it was made from. Deliberately
// not observable, and deliberately not @State + .onChange: measured
// 2026-09-03, that state write cost the home a second body pass per
// snapshot (30 -> 62 per minute) to save one regrouping.
@MainActor
final class HomeLayoutCache {
    private var inputs: [HomeHostInput]?
    private var selectedHostId: String?
    private var cached = HomeSections(computers: [], shown: [], severalShown: false, needsYou: [], projects: [])

    func sections(for inputs: [HomeHostInput], selectedHostId: String?) -> HomeSections {
        guard inputs != self.inputs || selectedHostId != self.selectedHostId else { return cached }
        self.inputs = inputs
        self.selectedHostId = selectedHostId
        let layout = HomeGrouping.layout(hosts: inputs)
        let shown = layout.computers.filter { selectedHostId == nil || $0.id == selectedHostId }
        cached = HomeSections(
            computers: layout.computers,
            shown: shown,
            severalShown: shown.count > 1,
            needsYou: layout.needsYou.filter { agent in shown.contains { $0.id == agent.hostId } },
            projects: shown.flatMap { computer in
                // A folder whose every agent is waiting above has nothing to
                // show here; a header pointing upward was noise (owner,
                // 2026-09-02 — supersedes the #26 "keeps its header" rule).
                computer.projects
                    .filter(\.hasRows)
                    .map { HomeProjectItem(computer: computer, project: $0) }
            }
        )
        return cached
    }
}
