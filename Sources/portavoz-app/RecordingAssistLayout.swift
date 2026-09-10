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

    /// Divides the height left after the recording bar and its banners. When
    /// the window is too short to honor both floors the assist area takes its
    /// floor and the captions keep the rest, because a caption strip degrades
    /// gracefully and a truncated assist panel does not.
    static func split(total: CGFloat, fraction: Double) -> Split {
        let usable = max(total - dividerHeight, 0)
        guard usable > 0 else { return Split(captions: 0, assist: 0) }
        guard usable >= minimumCaptionsHeight + minimumAssistHeight else {
            let assist = min(usable, minimumAssistHeight)
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

/// The assist area shows one panel at a time instead of stacking every panel
/// into a single scroll. The focus slot above the tabs keeps whatever cannot
/// wait for the user to switch (D504).
enum RecordingAssistTab: String, CaseIterable, Identifiable, Sendable {
    case companion
    case objectives
    case notes
    case interview
    case proactive
    case summary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .companion: L10n.text("Companion")
        case .objectives: L10n.text("Objectives")
        case .notes: L10n.text("Notes")
        case .interview: L10n.text("Interview")
        case .proactive: L10n.text("Suggestions")
        case .summary: L10n.text("Summary")
        }
    }

    var symbol: String {
        switch self {
        case .companion: "questionmark.bubble.fill"
        case .objectives: "target"
        case .notes: "square.and.pencil"
        case .interview: "person.wave.2"
        case .proactive: "lightbulb"
        case .summary: "sparkles"
        }
    }

    /// Companion, objectives and notes are always reachable. The other three
    /// appear only once they can show something, so the tab bar never offers a
    /// panel that would open empty.
    static func available(
        interviewEnabled: Bool,
        proactiveEnabled: Bool,
        hasSummary: Bool
    ) -> [RecordingAssistTab] {
        var tabs: [RecordingAssistTab] = [.companion, .objectives, .notes]
        if interviewEnabled { tabs.append(.interview) }
        if proactiveEnabled { tabs.append(.proactive) }
        if hasSummary { tabs.append(.summary) }
        return tabs
    }

    /// Keeps a selection valid when its tab disappears mid-recording.
    static func resolve(
        _ selection: RecordingAssistTab,
        in available: [RecordingAssistTab]
    ) -> RecordingAssistTab {
        available.contains(selection) ? selection : (available.first ?? .companion)
    }
}

/// What earns the one focus slot above the tabs.
enum RecordingFocusSlot: Equatable, Sendable {
    case none
    case catchUp
    case directedCard(UUID)
    case nextQuestion

    /// Catch-up wins because the user pressed the button seconds ago and is
    /// waiting for it. A question addressed to the user by name wins over the
    /// suggested next question, which is only ever advice.
    static func resolve(
        hasCatchUp: Bool,
        directedCardID: UUID?,
        hasNextQuestion: Bool
    ) -> RecordingFocusSlot {
        if hasCatchUp { return .catchUp }
        if let directedCardID { return .directedCard(directedCardID) }
        return hasNextQuestion ? .nextQuestion : .none
    }
}
