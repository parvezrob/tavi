import SwiftUI

// The one place the terminal screen reads the agent list. Its own view, so
// the home's snapshots invalidate this child alone and the screen around it
// hears only its own row change (#68 phone 5).
struct TerminalIdentityObserver: View {
    let directory: AgentDirectory?
    let paneID: String?
    @Binding var identity: AgentSummary?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: directory?.agents.first(where: { $0.id == paneID }), initial: true) { _, agent in
                identity = agent
            }
    }
}

extension TerminalSessionView {
    func identityHeader(_ agent: AgentSummary) -> some View {
        // In the terminal the dot beside the name is the *connection*:
        // green means live, and the banner row never has to exist for the
        // nominal case. Agent status lives on the home; here the transcript
        // itself shows what the agent is doing.
        // Your name for the tab beats the folder (#55); the folder beats a
        // shell's prompt string.
        let place = agent.userTabName
            ?? (agent.isShell ? HomeGrouping.projectName(of: agent.cwd) : agent.projectName)
        let location = [computerName, place].compactMap { $0 }.joined(separator: " · ")
        // One line, not a stack: a two-line title made the whole nav bar
        // tall. Name leads, the folder rides along in the quiet type.
        return HStack(spacing: 6) {
            Circle()
                .fill(connectionColor)
                .frame(width: 7, height: 7)
            Text(agent.displayName)
                .font(.subheadline.weight(.semibold))
            Text("· \(location)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.displayName), \(location), \(controller.connectionState.accessibilityDescription)")
        .accessibilityIdentifier("terminal.identity")
    }

    var connectionColor: Color {
        switch controller.connectionState {
        case .connected:
            .green
        case .connecting, .reconnecting, .waitingForNetwork:
            .orange
        case .failed, .ended:
            .red
        case .idle, .suspended:
            .secondary
        }
    }
}
