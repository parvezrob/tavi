import Foundation

// The home reads computer → project → agents (#26). A project is the folder
// an agent lives in — its cwd, nothing to name or maintain — and a computer
// is the host that reported it. Today one phone pairs with one computer, so
// the top level is a single quiet line; the model still carries it so that
// a second host (#50) nests under the same shape without a rewrite.
//
// What needs the user is deliberately *not* rendered inside the groups: a
// waiting agent must never sit under a project the eye has skipped, so
// needs-you stays a flat list above everything (PRD §7.1). The project it
// belongs to still knows about it — the header counts it — so a folder does
// not vanish and reappear as its agent blocks and resumes.
struct HomeProject: Identifiable, Equatable {
    // The cwd as the host reported it, trailing slashes trimmed. Two agents
    // in the same folder share a project; the phone does not try to be
    // cleverer about paths than the host that produced them.
    let path: String
    let name: String
    // Rendered flat above the groups, counted here.
    let needsYou: [AgentSummary]
    let active: [AgentSummary]
    let recent: [AgentSummary]

    var id: String { path }
    var abbreviatedPath: String { path.abbreviatingHomeDirectory }
    var agentCount: Int { needsYou.count + active.count + recent.count }
}

struct HomeComputer: Identifiable, Equatable {
    let id: String
    let name: String
    let projects: [HomeProject]
}

struct HomeLayout: Equatable {
    let needsYou: [AgentSummary]
    let computers: [HomeComputer]

    var isEmpty: Bool {
        needsYou.isEmpty && computers.allSatisfy { $0.projects.isEmpty }
    }
}

enum HomeGrouping {
    // Single-host layout. `computer` is whatever this phone knows the host
    // by (the paired name, else the address); agents never carry it, since
    // one directory serves one host.
    static func layout(agents: [AgentSummary], computer: (id: String, name: String)) -> HomeLayout {
        let needsYou = agents.filter { $0.homeSection == .needsYou }
        let projects = group(agents)
        let computers = projects.isEmpty
            ? []
            : [HomeComputer(id: computer.id, name: computer.name, projects: projects)]
        return HomeLayout(needsYou: needsYou, computers: computers)
    }

    // Projects by name; agents inside a project keep the host's order. The
    // order is deterministic and does not depend on status, so a project
    // never jumps around the screen as its agents start and finish — the
    // header's count says what is running.
    static func group(_ agents: [AgentSummary]) -> [HomeProject] {
        var order: [String] = []
        var members: [String: [AgentSummary]] = [:]

        for agent in agents {
            let path = projectPath(of: agent.cwd)
            if members[path] == nil { order.append(path) }
            members[path, default: []].append(agent)
        }

        return order
            .map { path in
                let agents = members[path] ?? []
                return HomeProject(
                    path: path,
                    name: projectName(of: path),
                    needsYou: agents.filter { $0.homeSection == .needsYou },
                    active: agents.filter { $0.homeSection == .active },
                    recent: agents.filter { $0.homeSection == .recent }
                )
            }
            .sorted { lhs, rhs in
                let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if byName != .orderedSame { return byName == .orderedAscending }
                return lhs.path < rhs.path
            }
    }

    static func projectPath(of cwd: String) -> String {
        var trimmed = cwd.trimmingCharacters(in: .whitespaces)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    // The folder's own name. The home directory is "Home", not the user's
    // login name; an empty path (a host that reported nothing) says so
    // rather than resolving against the app's working directory.
    static func projectName(of path: String) -> String {
        let path = projectPath(of: path)
        guard !path.isEmpty else { return "Unknown folder" }
        if path.abbreviatingHomeDirectory == "~" { return "Home" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty || name == "/" ? path : name
    }

    // What to call the paired computer: the name it gave when pairing, else
    // its address — the first DNS label when there is one, the whole thing
    // for an IP literal or a bare host typed into the dev form. Never empty:
    // the header is a landmark, not decoration.
    static func computerName(pairedName: String?, hostText: String) -> String {
        if let pairedName, !pairedName.trimmingCharacters(in: .whitespaces).isEmpty { return pairedName }
        let address = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URL(string: address)?.host()
            ?? address.split(separator: "/").first.map(String.init)
            ?? ""
        guard !host.isEmpty else { return "Paired computer" }
        let firstLabel = host.split(separator: ".").first.map(String.init) ?? host
        let isNumeric = !firstLabel.isEmpty && firstLabel.allSatisfy(\.isNumber)
        return isNumeric || host.contains(":") ? host : firstLabel
    }
}

extension String {
    // The path with the home prefix folded to "~" — the phone doesn't know
    // the host's home, so this is a display heuristic only.
    var abbreviatingHomeDirectory: String {
        replacingOccurrences(of: "^/(?:Users|home)/[^/]+", with: "~", options: .regularExpression)
    }
}
