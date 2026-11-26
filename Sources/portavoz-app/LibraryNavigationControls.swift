import SwiftUI

/// Presentation-only destinations remain available while an import is working.
struct LibraryNavigationControls: View {
    let route: Route?
    /// Generated suggestions waiting in Radar.
    var suggestionsToReview = 0
    let onNavigate: (Route) -> Void

    var body: some View {
        VStack(spacing: 2) {
            navigationButton(
                "Today", symbol: PVSymbol.today, id: "library-home-button",
                help: "See today's agenda, open to-dos, recent meetings and quick questions",
                shortcut: "1",
                selected: isHome) { onNavigate(.library) }
            navigationButton(
                "Ask", symbol: PVSymbol.ask, id: "library-ask-button",
                help: "Ask anything across every meeting",
                shortcut: "2",
                selected: route == .ask) { onNavigate(.ask) }
            navigationButton(
                "Insights", symbol: "chart.bar.xaxis", id: "library-insights-button",
                help: "See totals, cadence, people and commitments",
                shortcut: "3",
                selected: route == .insights) { onNavigate(.insights) }
            navigationButton(
                "Radar", symbol: PVSymbol.radar, id: "library-commitment-radar-button",
                help: "Track confirmed commitments, deadlines, sources and changes",
                shortcut: "4",
                selected: route?.isCommitmentRadar == true, badge: suggestionsToReview) {
                onNavigate(.commitments(nil))
            }
        }
    }

    /// Home owns the empty route as well as the explicit `.library` route.
    private var isHome: Bool {
        route == nil || route == .library
    }

    private func navigationButton(
        _ title: LocalizedStringKey, symbol: String, id: String, help: String,
        shortcut: KeyEquivalent,
        selected: Bool = false, badge: Int = 0, action: @escaping () -> Void
    ) -> some View {
        let badgeText = badge > 0 ? badge.formatted(.number.locale(AppLanguage.current.locale)) : ""
        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected ? PVDesign.accent : PVDesign.ink3)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.body.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text(badgeText)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(PVDesign.ink2)
                        .accessibilityIdentifier("\(id)-badge")
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .contentShape(.rect)
            .background(
                selected ? PVDesign.accent.opacity(PVDesign.chipTint) : .clear,
                in: RoundedRectangle(cornerRadius: PVDesign.radiusSmall))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
        .accessibilityLabel(Text(title))
        .accessibilityValue(badgeText)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
        .help(L10n.text(help))
    }
}
