import ApplicationKit
import PortavozCore

/// Decides when a meeting's voice suggestions need the voiceprint pass again
/// and which chips may still show. Speakers can appear after the first load
/// (diarization, Refine), so each new unnamed speaker earns one evaluation.
struct MeetingDetailVoiceSuggestionGate {
    private var evaluated: Set<String> = []
    private var dismissed: Set<String> = []

    /// True when an unnamed speaker has not been evaluated yet; marks them evaluated.
    mutating func begin(speakers: [Speaker]) -> Bool {
        let pending = Self.unnamedLabels(speakers).subtracting(evaluated)
        evaluated.formUnion(pending)
        return !pending.isEmpty
    }

    mutating func dismiss(_ speakerLabel: String) {
        dismissed.insert(speakerLabel)
    }

    /// Drops chips for speakers that now have a name, left the cast, or were dismissed.
    func visible(
        _ suggestions: [MeetingVoiceSuggestion],
        speakers: [Speaker]
    ) -> [MeetingVoiceSuggestion] {
        let unnamed = Self.unnamedLabels(speakers)
        return suggestions.filter {
            unnamed.contains($0.speakerLabel) && !dismissed.contains($0.speakerLabel)
        }
    }

    private static func unnamedLabels(_ speakers: [Speaker]) -> Set<String> {
        Set(speakers.filter { !$0.isMe && $0.displayName == nil }.map(\.label))
    }
}
