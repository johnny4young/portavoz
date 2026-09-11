import PortavozCore
import SwiftUI

/// One explicit rolling update-time lens for the bounded activity query.
/// The parent owns selection so lifecycle, Skill, period, and window changes
/// share one generation-fenced load instead of filtering rows in the view.
struct SkillActivityPeriodFilter: View {
    @Binding var receiptPeriod: SkillExecutionReviewPeriod

    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Updated")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                periodButton(.anytime, identifier: "anytime")
                periodButton(.pastDay, identifier: "past-day")
                periodButton(.pastWeek, identifier: "past-week")
                periodButton(.pastMonth, identifier: "past-month")
            } label: {
                Text(Self.title(receiptPeriod))
                    .lineLimit(1)
                    .frame(minWidth: 180, alignment: .leading)
            }
            .accessibilityLabel("Filter activity by update time")
            .accessibilityValue(Self.title(receiptPeriod))
            .accessibilityIdentifier(
                "settings-skills-receipt-period-filter")
            .disabled(isDisabled)
        }
    }

    static func title(_ period: SkillExecutionReviewPeriod) -> String {
        switch period {
        case .anytime: L10n.text("Any time")
        case .pastDay: L10n.text("Past 24 hours")
        case .pastWeek: L10n.text("Past 7 days")
        case .pastMonth: L10n.text("Past 30 days")
        }
    }

    private func periodButton(
        _ period: SkillExecutionReviewPeriod,
        identifier: String
    ) -> some View {
        Button(Self.title(period)) {
            receiptPeriod = period
        }
        .accessibilityIdentifier(
            "settings-skills-receipt-period-\(identifier)")
    }
}
