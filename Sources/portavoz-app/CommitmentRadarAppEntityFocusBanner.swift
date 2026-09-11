import PortavozCore
import SwiftUI

/// A system-provided App Entity focus is visible and reversible; it never
/// masquerades as the user's durable Radar filter selection.
struct CommitmentRadarAppEntityFocusBanner: View {
    let focus: CommitmentRadarRouteFocus?
    let page: CommitmentRadarPage?
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: "arrow.triangle.turn.up.right.circle")
                .font(.callout.weight(.medium))
                .accessibilityIdentifier("commitment-radar-app-entity-focus")
            Spacer()
            Button("Show all", action: clear)
                .accessibilityIdentifier("commitment-radar-clear-app-entity-focus")
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private var title: String {
        switch focus {
        case .person:
            let name = page?.items.first?.assigneeDisplayName
                ?? L10n.text("Selected person")
            return L10n.format("Commitments for %@", name)
        case .commitment:
            let value = page?.items.first?.commitment.title
                ?? L10n.text("Selected commitment")
            return L10n.format("Opened commitment: %@", value)
        case nil:
            return ""
        }
    }
}
