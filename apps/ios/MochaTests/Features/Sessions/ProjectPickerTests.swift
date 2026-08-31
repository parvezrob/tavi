import Foundation
import Testing
@testable import Mocha

struct ProjectPickerTests {
    private let catalog = ProjectCatalog(
        recent: [
            ProjectFolder(path: "/Users/dev/Projects/mocha", name: "mocha", active: true, withinRoots: true),
            ProjectFolder(path: "/Users/dev/Projects/api", name: "api", active: false, withinRoots: true),
        ],
        workspaces: [
            ProjectWorkspace(name: "api", path: "/Users/dev/Projects/api", git: true),
            ProjectWorkspace(name: "web", path: "/Users/dev/Projects/web", git: true),
            ProjectWorkspace(name: "notes", path: "/Users/dev/Projects/notes", git: false),
        ],
        roots: ["/Users/dev/Projects"]
    )

    @Test
    func keepsHostOrderAndDoesNotRepeatARecentFolderUnderProjects() {
        let sections = ProjectPicker.sections(for: catalog, query: "")

        #expect(sections.recent.map(\.path) == [
            "/Users/dev/Projects/mocha",
            "/Users/dev/Projects/api",
        ])
        // "api" is already in Recent, so Projects shows only what is new.
        #expect(sections.projects.map(\.name) == ["web", "notes"])
        #expect(sections.isEmpty == false)
    }

    @Test
    func searchMatchesFolderNamesAndPathsInBothSections() {
        #expect(ProjectPicker.sections(for: catalog, query: "AP").recent.map(\.name) == ["api"])
        #expect(ProjectPicker.sections(for: catalog, query: "AP").projects.isEmpty)
        #expect(ProjectPicker.sections(for: catalog, query: "note").projects.map(\.name) == ["notes"])
        #expect(ProjectPicker.sections(for: catalog, query: "  ").recent.count == 2)
        // Both recent entries match this path, so the de-duplication above
        // removes "api" from Projects and two workspaces remain.
        #expect(ProjectPicker.sections(for: catalog, query: "/Users/dev").recent.count == 2)
        #expect(ProjectPicker.sections(for: catalog, query: "/Users/dev").projects.map(\.name) == ["web", "notes"])
    }

    @Test
    func aSearchThatMatchesNothingReportsAnEmptyPicker() {
        let sections = ProjectPicker.sections(for: catalog, query: "nothing-here")

        #expect(sections.isEmpty)
    }

    @Test
    func aFolderHiddenFromRecentBySearchIsStillOfferedUnderProjects() {
        // Only the path matches, and only in the workspace entry's spelling —
        // filtering happens per section, so the row does not vanish entirely.
        let sections = ProjectPicker.sections(for: catalog, query: "web")

        #expect(sections.recent.isEmpty)
        #expect(sections.projects.map(\.name) == ["web"])
    }
}
