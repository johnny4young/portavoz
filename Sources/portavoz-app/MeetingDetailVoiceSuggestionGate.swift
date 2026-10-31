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

/// Voice chips and voice-applied names for one open meeting.
struct MeetingDetailVoiceSuggestions {
    private(set) var offered: [MeetingVoiceSuggestion] = []
    /// Applied without a tap and still undoable from the header.
    private(set) var autoAssigned: [MeetingVoiceSuggestion] = []
    private var gate = MeetingDetailVoiceSuggestionGate()

    mutating func begin(speakers: [Speaker]) -> Bool {
        gate.begin(speakers: speakers)
    }

    /// Offers the matches that may still show and returns the ones to apply without a tap.
    mutating func receive(
        _ loaded: [MeetingVoiceSuggestion], speakers: [Speaker], canAutoAssign: Bool
    ) -> [MeetingVoiceSuggestion] {
        let visible = gate.visible(loaded, speakers: speakers)
        let automatic = canAutoAssign ? visible.filter(\.isAutoAssignable) : []
        offered = visible.filter { !automatic.contains($0) }
        return automatic
    }

    mutating func offer(_ suggestion: MeetingVoiceSuggestion) {
        offered.append(suggestion)
    }

    mutating func accepted(_ speakerLabel: String) {
        offered.removeAll { $0.speakerLabel == speakerLabel }
    }

    mutating func assigned(_ suggestion: MeetingVoiceSuggestion) {
        autoAssigned.append(suggestion)
    }

    mutating func dismiss(_ speakerLabel: String) {
        gate.dismiss(speakerLabel)
        offered.removeAll { $0.speakerLabel == speakerLabel }
    }

    mutating func keep(_ speakerLabel: String) {
        autoAssigned.removeAll { $0.speakerLabel == speakerLabel }
    }

    /// Retires the applied match so the same voice is not offered again while the meeting is open.
    mutating func undo(_ speakerLabel: String) -> MeetingVoiceSuggestion? {
        guard let assigned = autoAssigned.first(where: { $0.speakerLabel == speakerLabel }) else { return nil }
        keep(speakerLabel)
        gate.dismiss(speakerLabel)
        return assigned
    }

    /// A projection still in flight from before the rename may lack the name; the mark stays then.
    mutating func follow(speakers: [Speaker]) {
        offered = gate.visible(offered, speakers: speakers)
        autoAssigned.removeAll { assigned in
            let speaker = speakers.first { $0.label == assigned.speakerLabel }
            return speaker == nil || (speaker?.displayName).map { $0 != assigned.name } == true
        }
    }
}
