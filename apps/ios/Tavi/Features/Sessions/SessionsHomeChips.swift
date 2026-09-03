import SwiftUI

// The computer strip at the top of the home (#50): one chip per paired
// computer, and the "All" chip that is not one.

// One computer per chip (#50), in the strip at the top of the home: the
// dot is its health, the word after the name is the health when it is
// anything but live, and the amber numeral is how many of its agents are
// waiting on you — so the strip is also the fleet at a glance. A tap
// filters the home to that computer. With one computer the strip is a
// single pill that opens the computer's sheet, and the numeral stays off:
// the "Needs you" header right beneath already says it.
struct ComputerChip: View {
    let computer: HomeComputer
    let isSelected: Bool
    var showsWaitingCount = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if computer.health == .stale || computer.health == .connecting {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill(HostHealthLabel.color(for: computer.health))
                        .frame(width: 6, height: 6)
                }
                Text(computer.name)
                    .font(.footnote.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)
                if computer.health != .live {
                    Text("· \(computer.health.label(latencyMilliseconds: nil, connection: computer.connection))")
                        .font(.footnote)
                        .foregroundStyle(HostHealthLabel.color(for: computer.health))
                        .lineLimit(1)
                }
                if showsWaitingCount, computer.waitingCount > 0 {
                    Text("\(computer.waitingCount)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(TaviTheme.accentInk)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(TaviTheme.accent, in: Capsule())
                }
            }
            .foregroundStyle(isSelected ? TaviTheme.textPrimary : TaviTheme.textSecondary)
            .padding(.horizontal, TaviTheme.Spacing.snug)
            .padding(.vertical, 8)
            .background(isSelected ? TaviTheme.card : TaviTheme.canvas, in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? TaviTheme.textSecondary.opacity(0.5) : TaviTheme.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(computer.name)
        .accessibilityValue(computer.summary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("sessions.computer.\(computer.id)")
    }
}

// "All" — every computer at once; the default, and the only chip that is
// not a computer.
struct AllComputersChip: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("All")
                .font(.footnote.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? TaviTheme.textPrimary : TaviTheme.textSecondary)
                .padding(.horizontal, TaviTheme.Spacing.card)
                .padding(.vertical, 8)
                .background(isSelected ? TaviTheme.card : TaviTheme.canvas, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? TaviTheme.textSecondary.opacity(0.5) : TaviTheme.hairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("sessions.computer.all")
    }
}

// The host tier: a row of chips — All, then every computer, in pairing
// order (#50). With one computer, one status pill. Tap filters; a long
// press opens the computer's sheet (address, round trip, rename, unpair).
struct ComputerStrip: View {
    let computers: [HomeComputer]
    @Binding var selectedHostId: String?
    let onOpenComputer: (HomeComputer) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if computers.count > 1 {
                    AllComputersChip(isSelected: selectedHostId == nil) { selectedHostId = nil }
                }
                ForEach(computers) { computer in
                    ComputerChip(
                        computer: computer,
                        isSelected: computers.count > 1 && selectedHostId == computer.id,
                        showsWaitingCount: computers.count > 1
                    ) {
                        if computers.count > 1 {
                            selectedHostId = selectedHostId == computer.id ? nil : computer.id
                        } else {
                            onOpenComputer(computer)
                        }
                    }
                    .contextMenu {
                        Button("About \(computer.name)", systemImage: "info.circle") {
                            onOpenComputer(computer)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("sessions.computers")
    }
}
