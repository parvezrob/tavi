import SwiftUI

// A section label in the Orca register: 12 pt small caps, wide tracking,
// an optional trailing count, and room at the end for the section's one
// quiet action (Stage all, Push, Pull main in — PRD §7.15). The count is
// the only place a section shouts, and only "Needs you" is allowed to
// shout in amber. One register for the home and every sheet: nothing
// re-draws it by hand.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var count: Int? = nil
    var countTint: Color = TaviTheme.textSecondary
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .kerning(1.1)
                .textCase(.uppercase)
                .foregroundStyle(TaviTheme.textSecondary)
            if let count {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(countTint)
            }
            Spacer(minLength: 0)
            // A List's header uppercases its children; the action is a
            // sentence, not a label.
            trailing()
                .font(.footnote)
                .textCase(nil)
                .foregroundStyle(TaviTheme.textSecondary)
        }
        .padding(.leading, 2)
        // Label and count read as one heading; an action stays its own
        // element so VoiceOver can press it.
        .accessibilityElement(children: Trailing.self == EmptyView.self ? .combine : .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil, countTint: Color = TaviTheme.textSecondary) {
        self.init(title: title, count: count, countTint: countTint) { EmptyView() }
    }
}
