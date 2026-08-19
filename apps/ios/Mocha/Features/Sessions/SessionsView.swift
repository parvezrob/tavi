import SwiftUI

struct SessionsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Phase 1 development") {
                    NavigationLink {
                        TerminalSessionView()
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
        }
    }
}

#Preview {
    SessionsView()
}
