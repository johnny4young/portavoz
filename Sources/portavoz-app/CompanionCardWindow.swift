import Foundation
import PortavozCore

/// How much of one Companion card the live list shows.
enum CompanionCardPresentation: Equatable, Sendable {
    /// Question only, one line — everything past the recency window.
    case collapsed
    /// Question plus a few lines of answer: the default for what just arrived.
    case clamped
    /// The whole card, because the user opened it.
    case full
}

/// The live Apuntador list rendered every card at its full ideal height,
/// newest first, none dropped. One real 18-minute meeting produced 23 cards —
/// nine of them dismissed by hand during the call — and only two were
/// addressed to the user. Now the newest few stay open, the rest keep their
/// question on one line until the user opens them, and the one directed card
/// is lifted out to the focus slot instead of competing with the other 21
/// (D504).
enum CompanionCardWindow {
    /// Cards kept open at once. Three fills the assist area at its default
    /// height without pushing the tab bar off screen.
    static let expandedLimit = 3
    /// Lines of answer a `clamped` card shows.
    static let clampedAnswerLines = 4
    /// An answer longer than this cannot fit `clampedAnswerLines`, so the card
    /// offers to open fully. Steadier and cheaper than measuring the text.
    static let openFullyAboveCharacters = 220

    struct Row: Identifiable, Equatable, Sendable {
        let card: CompanionCard
        let presentation: CompanionCardPresentation

        var id: UUID { card.id }

        var canOpenFully: Bool {
            presentation == .clamped
                && card.answer.count > CompanionCardWindow.openFullyAboveCharacters
        }
    }

    /// Newest first, minus the card already shown in the focus slot.
    ///
    /// Cards the user opened by hand claim the window first, so reaching back
    /// for an older card folds the oldest card that was only open by recency
    /// instead of making the list taller. Opening more than `expandedLimit` by
    /// hand does grow it — that is the user asking for it, repeatedly.
    static func rows(
        cards: [CompanionCard],
        focused: UUID?,
        overrides: [UUID: CompanionCardPresentation]
    ) -> [Row] {
        let visible = cards.reversed().filter { $0.id != focused }
        let chosenOpen = visible.filter { overrides[$0.id].map { $0 != .collapsed } ?? false }
        var budget = max(0, expandedLimit - chosenOpen.count)

        return visible.map { card in
            if let chosen = overrides[card.id] {
                return Row(card: card, presentation: chosen)
            }
            guard budget > 0 else { return Row(card: card, presentation: .collapsed) }
            budget -= 1
            return Row(card: card, presentation: .clamped)
        }
    }

    /// The newest question addressed to the user by name — the one card that
    /// earns the focus slot. Undirected context cards never take it.
    static func focusCard(_ cards: [CompanionCard]) -> CompanionCard? {
        cards.last { $0.directed }
    }
}
