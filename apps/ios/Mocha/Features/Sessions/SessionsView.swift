import SwiftUI

struct SessionsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("No Sessions", systemImage: "terminal")
            } description: {
                Text("Pair a computer to see and resume its durable terminal sessions.")
            }
            .navigationTitle("Mocha")
            .accessibilityIdentifier("sessions.empty")
        }
    }
}

#Preview {
    SessionsView()
}
