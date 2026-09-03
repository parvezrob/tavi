import SwiftUI

// Pairing is the way in (#45); this typed host/token form survives only for
// simulator and UI-test runs, and the home offers it under #if DEBUG.
struct HostTokenForm: View {
    @Binding var address: String
    @Binding var token: String
    let onDismiss: () -> Void
    let onSave: (String, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("https://your-mac.tailnet.ts.net", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section {
                    SecureField("Access token", text: $token)
                } header: {
                    Text("Access token")
                } footer: {
                    Text("Stored in this iPhone's Keychain, on this device only. Tavi never uploads it. Anyone with this token can run commands on that computer.")
                }
            }
            .navigationTitle("Connect Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedAddress.isEmpty, !trimmedToken.isEmpty {
                            onSave(trimmedAddress, trimmedToken)
                        }
                        onDismiss()
                    }
                }
            }
        }
    }
}
