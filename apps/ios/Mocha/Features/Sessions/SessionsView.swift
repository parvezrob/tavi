import SwiftUI

struct SessionsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var terminalController = TerminalSessionController()

    var body: some View {
        NavigationStack {
            List {
                Section("Phase 1 development") {
                    NavigationLink {
                        TerminalSessionView(controller: terminalController)
                    } label: {
                        Label("Open terminal", systemImage: "terminal")
                    }
                    .accessibilityIdentifier("sessions.openTerminal")
                }

                Section {
                    ContentUnavailableView {
                        Label("No Paired Computers", systemImage: "desktopcomputer")
                    } description: {
                        Text("Secure pairing and the multi-session home arrive after the terminal path is qualified.")
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Mocha")
            .accessibilityIdentifier("sessions.list")
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    terminalController.sceneDidBecomeActive()
                case .background:
                    terminalController.sceneWillResignActive()
                case .inactive:
                    break
                @unknown default:
                    terminalController.sceneWillResignActive()
                }
            }
        }
    }
}

#Preview {
    SessionsView()
}
