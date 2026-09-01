import SwiftUI

// "This iPhone" for one paired computer (#46, #50): what that host knows
// this phone as, and the way out. Unpairing asks the host to revoke this
// phone's own credential, then forgets it locally; the other paired
// computers are untouched. If the host cannot be reached the phone can
// still forget — but it says plainly that the computer still lists it
// until revoked there, because pretending otherwise would be a lie about
// access.
struct ManageAccessView: View {
    let host: PairedHost
    let directory: AgentDirectory
    let onForget: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var unpairing = false
    @State private var failure: String?
    @State private var confirmingForget = false

    var body: some View {
        NavigationStack {
            List {
                // Placeholders never ship ("Name: Unknown" reads broken,
                // #54): a host typed by address has no fingerprint or
                // device name, and those rows simply don't render.
                Section("Paired computer") {
                    row("Name", host.displayName)
                    row("Address", host.address.replacingOccurrences(of: "https://", with: ""))
                    if let fingerprint = host.fingerprint {
                        row("Fingerprint", fingerprint, monospaced: true)
                    }
                    HStack {
                        Text("Connection")
                            .foregroundStyle(TaviTheme.textSecondary)
                        Spacer()
                        HostHealthLabel(health: directory.health, latencyMilliseconds: directory.latencyMilliseconds)
                    }
                    .accessibilityElement(children: .combine)
                }
                .listRowBackground(TaviTheme.card)

                Section("This iPhone") {
                    if let deviceName = host.deviceName {
                        row("Known as", deviceName)
                    }
                    row("Paired", host.pairedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .listRowBackground(TaviTheme.card)

                Section {
                    Button(role: .destructive) {
                        Task { await unpair() }
                    } label: {
                        HStack {
                            if unpairing { ProgressView().controlSize(.small) }
                            Text("Unpair this iPhone")
                        }
                    }
                    .disabled(unpairing)
                    .accessibilityIdentifier("manageAccess.unpair")
                } footer: {
                    if let failure {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(failure)
                                .foregroundStyle(TaviTheme.statusBlocked)
                            Button("Forget on this iPhone only") { confirmingForget = true }
                                .font(.footnote)
                                .accessibilityIdentifier("manageAccess.forgetOnly")
                        }
                    } else {
                        Text("Revokes this phone's access on \(host.displayName) and forgets it here. Your agents keep running; other paired computers are not affected. On the computer itself: `npx tavi-host devices revoke`.")
                    }
                }
                .listRowBackground(TaviTheme.card)
            }
            .scrollContentBackground(.hidden)
            .background(TaviTheme.canvas.ignoresSafeArea())
            .navigationTitle("This iPhone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("manageAccess.done")
                }
            }
            .confirmationDialog(
                "\(host.displayName) will still list this iPhone until you revoke it there.",
                isPresented: $confirmingForget,
                titleVisibility: .visible
            ) {
                Button("Forget on this iPhone", role: .destructive) {
                    onForget()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(TaviTheme.textSecondary)
            Spacer()
            Text(value)
                .font(monospaced ? .body.monospaced() : .body)
                .foregroundStyle(TaviTheme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func unpair() async {
        unpairing = true
        defer { unpairing = false }
        failure = nil
        if let message = await directory.unpairSelf() {
            failure = message
            return
        }
        onForget()
        dismiss()
    }
}
