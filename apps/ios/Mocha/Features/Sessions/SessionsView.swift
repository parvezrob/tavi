import SwiftUI

struct SessionsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var terminalController = TerminalSessionController()
    @State private var terminalIsPresented = false

    var body: some View {
        NavigationStack {
            List {
                Section("Phase 1 development") {
                    Button {
                        terminalIsPresented = true
                    } label: {
                        Label("Open terminal", systemImage: "terminal")
                    }
                    .foregroundStyle(.primary)
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
            .navigationDestination(isPresented: $terminalIsPresented) {
                TerminalSessionView(controller: terminalController)
            }
            .task {
                #if DEBUG
                // Scripted development runs (simulator automation) jump
                // straight to the terminal without a tap.
                if ProcessInfo.processInfo.environment["MOCHA_DEV_AUTO_OPEN_TERMINAL"] == "1" {
                    terminalIsPresented = true
                }
                #endif
            }
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
