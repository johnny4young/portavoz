import SwiftUI

/// A Today section title in the display face, with an optional trailing control.
struct HomeSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .pvDisplay(.section)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: PVDesign.space2)
            trailing()
        }
        .frame(minHeight: 28)
    }
}

extension HomeSectionHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// The hairline above each Today row.
struct HomeSectionRule: View {
    var body: some View {
        Rectangle().fill(PVDesign.line).frame(height: 1)
    }
}

/// The line a Today section shows when it has no rows.
struct HomeSectionEmpty: View {
    let key: LocalizedStringKey

    var body: some View {
        HomeSectionRule()
        Text(key)
            .font(.callout)
            .foregroundStyle(PVDesign.ink3)
            .padding(.vertical, 10)
    }
}

/// A small capsule label; amber only when it names you.
struct HomeChip: View {
    let text: String
    var isYou = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(isYou ? PVDesign.youInk : PVDesign.ink)
            .pvPill(isYou ? PVDesign.youBg : PVDesign.line)
            .fixedSize()
    }
}
