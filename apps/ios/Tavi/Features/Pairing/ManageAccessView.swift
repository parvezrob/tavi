import SwiftUI

// "This iPhone" (#46): what the host knows this phone as, and the way out.
// Unpairing asks the host to revoke this phone's own credential, then
// forgets it locally. If the host cannot be reached the phone can still
// forget — but it says plainly that the Mac still lists it until revoked
// there, because pretending otherwise would be a lie about access.
struct ManageAccessView: View {
    let record: PairedHostRecord?
    let hostAddress: String
    let directory: AgentDirectory
    let onForget: () -> Void
    let onPairAnother: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var unpairing = false
    @State private var failure: String?
    @State private var confirmingForget = false

    var body: some View {
        NavigationStack {
            List {
                // Placeholders never ship ("Name: Unknown" reads broken,
                // #54): with no pairing record the address stands in as the
                // name and the empty rows simply don't render.
                Section("Paired Mac") {
                    row("Name", HomeGrouping.computerName(pairedName: record?.hostName, hostText: hostAddress))
                    row("Address", hostAddress.replacingOccurrences(of: "https://", with: ""))
                    if let fingerprint = record?.fingerprint {
                        row("Fingerprint", fingerprint, monospaced: true)
                    }
                }
                .listRowBackground(TaviTheme.card)

                if record != nil {
                    Section("This iPhone") {
                        if let deviceName = record?.deviceName {
                            row("Known to the Mac as", deviceName)
                        }
                        if let pairedAt = record?.pairedAt {
                            row("Paired", pairedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    .listRowBackground(TaviTheme.card)
                }

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
                        Text("Revokes this phone's access on the Mac and forgets the Mac here. Your agents keep running. You can also revoke from the Mac with `tavi devices revoke`.")
                    }
                }
                .listRowBackground(TaviTheme.card)

                Section {
                    Button("Pair a different Mac") {
                        dismiss()
                        onPairAnother()
                    }
                    .accessibilityIdentifier("manageAccess.pairAnother")
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
                "The Mac will still list this iPhone until you revoke it there.",
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
