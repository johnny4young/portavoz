import Foundation

/// How the live recording screen divides its flexible height between the
/// captions and the assist area.
///
/// The assist area used to be pinned at `maxHeight: 260` while the captions
/// took every flexible point, so a taller window grew only the captions and
/// eight panels competed inside a box that never moved. One real 18-minute
/// meeting put roughly 1 950 pt of content in it (D504).
enum RecordingAssistLayout {
    /// Neither zone may collapse: the captions are the meeting, and the
    /// assist area is why the window is open at all.
    static let minimumFraction = 0.25
    static let maximumFraction = 0.70
    static let defaultFraction = 0.42
    static let minimumCaptionsHeight: CGFloat = 132
    static let minimumAssistHeight: CGFloat = 168
    /// Pointer target for the divider; the visible capsule is thinner.
    static let dividerHeight: CGFloat = 14
    /// One keyboard or VoiceOver step on the divider.
    static let fractionStep = 0.05

    struct Split: Equatable {
        let captions: CGFloat
        let assist: CGFloat
    }

    static func clamp(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return defaultFraction }
        return min(max(fraction, minimumFraction), maximumFraction)
    }

    /// Divides the height left after the recording bar and its banners.
    ///
    /// When the window is too short to honor both floors, both shrink in
    /// proportion. Paying one floor in full drove the other to zero — with
    /// several banners stacked on a small window the captions disappeared and
    /// the meeting had no words on screen (D507). Rounding down and clamping
    /// keeps the arithmetic from handing SwiftUI a negative frame in the last
    /// couple of points before the split is degenerate anyway (D508).
    static func split(total: CGFloat, fraction: Double) -> Split {
        guard total.isFinite else { return Split(captions: 0, assist: 0) }
        let usable = max(total - dividerHeight, 0)
        guard usable > 0 else { return Split(captions: 0, assist: 0) }
        guard usable >= minimumCaptionsHeight + minimumAssistHeight else {
            let proportional = (usable * minimumAssistHeight
                / (minimumCaptionsHeight + minimumAssistHeight)).rounded(.down)
            let assist = min(max(proportional, 0), usable)
            return Split(captions: usable - assist, assist: assist)
        }
        let requested = (usable * clamp(fraction)).rounded()
        let bounded = min(
            max(requested, minimumAssistHeight),
            usable - minimumCaptionsHeight)
        return Split(captions: usable - bounded, assist: bounded)
    }

    /// The fraction after dragging the divider up by `points` — up grows the
    /// assist area, which is the direction the handle appears to move.
    static func fraction(
        from anchor: Double,
        draggedUpBy points: CGFloat,
        total: CGFloat
    ) -> Double {
        let usable = max(total - dividerHeight, 1)
        return clamp(anchor + Double(points) / Double(usable))
    }
}

/// The assist area keeps three tabs: Apuntador (questions, interview and
/// proactive signals), Objectives, and Notes with the running summary. The
/// focus slot under the tabs lifts urgent cards (D504).
enum RecordingAssistTab: String, CaseIterable, Identifiable, Sendable {
    case companion
    case objectives
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .companion: L10n.text("Apuntador")
        case .objectives: L10n.text("Objectives")
        case .notes: L10n.text("Notes")
        }
    }
}

/// What earns the one focus slot above the tabs.
enum RecordingFocusSlot: Equatable, Sendable {
    case none
    case catchUp
    case directedCard(UUID)
    case nextQuestion

    /// What the user just asked for comes first, then what arrived on its own.
    ///
    /// Catch-up and the suggested next question are there because the user
    /// pressed a button seconds ago; a directed card arrives unbidden. Ranking
    /// the directed card higher meant one undismissed card silently swallowed
    /// every later press of "Suggest a question" for the rest of the meeting —
    /// the button did nothing, not even show its spinner. Nothing is lost by
    /// the order: a directed card is also reachable in the Companion tab,
    /// while the other two have this slot as their only home (D508).
    static func resolve(
        hasCatchUp: Bool,
        directedCardID: UUID?,
        hasNextQuestion: Bool
    ) -> RecordingFocusSlot {
        if hasCatchUp { return .catchUp }
        if hasNextQuestion { return .nextQuestion }
        if let directedCardID { return .directedCard(directedCardID) }
        return .none
    }
}

/// When the live voices and the assist panel share a row.
enum RecordingStageLayout {
    /// The board's panel: 322 pt beside a 620 pt table, about a third of the row.
    static let panelWidth: CGFloat = 322
    static let panelShare: CGFloat = 0.34
    static let columnGap: CGFloat = 40
    /// The voices table's narrow metrics with a usable bar.
    static let minimumVoicesWidth: CGFloat = 400
    /// The panel never shrinks below its tabs, a card and the note field.
    static let panelMinimumHeight: CGFloat = 300
    static let horizontalPadding: CGFloat = 20

    static func isSideBySide(width: CGFloat) -> Bool {
        width >= minimumVoicesWidth + columnGap + panelWidth + 2 * horizontalPadding
    }

    /// The panel keeps the board's share of a wide row, never under 322 pt.
    static func panelWidth(for width: CGFloat) -> CGFloat {
        guard width.isFinite else { return panelWidth }
        return max(panelWidth, ((width - 2 * horizontalPadding) * panelShare).rounded())
    }
}
