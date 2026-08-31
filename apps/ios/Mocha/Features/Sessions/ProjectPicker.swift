import Foundation

// The New Agent picker's list, derived from the host's catalog (#24). Pure
// so the ordering and de-duplication rules are testable without a view: the
// host owns which folders exist and in what order, this owns what the two
// sections show once a search narrows them.
enum ProjectPicker {
    struct Sections: Equatable {
        var recent: [ProjectFolder]
        var projects: [ProjectWorkspace]

        var isEmpty: Bool { recent.isEmpty && projects.isEmpty }
    }

    static func sections(for catalog: ProjectCatalog, query: String) -> Sections {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let recent = catalog.recent.filter { matches($0.name, $0.path, needle) }
        // A folder that is already in Recent is not repeated below it.
        let alreadyListed = Set(recent.map(\.path))
        let projects = catalog.workspaces.filter {
            !alreadyListed.contains($0.path) && matches($0.name, $0.path, needle)
        }
        return Sections(recent: recent, projects: projects)
    }

    private static func matches(_ name: String, _ path: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        return name.lowercased().contains(needle) || path.lowercased().contains(needle)
    }
}
