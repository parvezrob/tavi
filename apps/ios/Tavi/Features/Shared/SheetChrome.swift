import SwiftUI

// The two ways every sheet says "wait" and "here is why not" (#92). Source
// Control speaks a size down from Files and Preview; Preview stacks its
// card above the port field instead of filling the tab.
struct LoadingRow: View {
    let text: String
    let font: Font

    init(_ text: String, font: Font = .callout) {
        self.text = text
        self.font = font
    }

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text)
                .font(font)
                .foregroundStyle(TaviTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MessageCard: View {
    let text: String
    let identifier: String
    let font: Font
    let fillsTab: Bool

    init(_ text: String, identifier: String, font: Font = .callout, fillsTab: Bool = true) {
        self.text = text
        self.identifier = identifier
        self.font = font
        self.fillsTab = fillsTab
    }

    var body: some View {
        if fillsTab {
            VStack {
                card
                    .accessibilityIdentifier(identifier)
                Spacer()
            }
            .padding(16)
        } else {
            card
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .accessibilityIdentifier(identifier)
        }
    }

    private var card: some View {
        Text(text)
            .font(font)
            .foregroundStyle(TaviTheme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(20)
            .frame(maxWidth: .infinity)
            .taviCard()
    }
}
