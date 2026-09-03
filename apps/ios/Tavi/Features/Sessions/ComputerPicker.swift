import SwiftUI

// The first question when several computers are paired (#50): which
// one. Health is on every row so a sleeping machine is a known quantity
// before its folders fail to load.
struct ComputerPicker: View {
    let computers: [HostFleet.Entry]
    let onChoose: (HostFleet.Entry) -> Void

    var body: some View {
        List {
            Section {
                ForEach(computers) { entry in
                    Button {
                        onChoose(entry)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(TaviTheme.textSecondary)
                            Text(entry.host.displayName)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(TaviTheme.textPrimary)
                            Spacer(minLength: 8)
                            HostHealthLabel(
                                health: entry.directory.health,
                                latencyMilliseconds: entry.directory.latencyMilliseconds
                            )
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(TaviTheme.textSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("newAgent.computer.\(entry.id)")
                }
            } header: {
                Text("Which computer?")
            }
            .listRowBackground(TaviTheme.card)
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("newAgent.computers")
    }
}
