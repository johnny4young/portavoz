import Foundation
import TranscriptionKit

/// This is a live-lane choice, not a replacement for the durable batch model.
/// Meetings default to Parakeet v3; dictation's choice and its Ultra default (D613)
/// live in LiveSpeechSelection+Dictation.swift.
enum LiveSpeechSelection: String, CaseIterable {
    case parakeet
    /// Dictation only; meetings keep v3.
    case parakeetUltra
    case appleSpeech

    static let meetingKey = "meetingLiveSpeechEngine"

    static func meeting(defaults: UserDefaults = .standard) -> Self {
        let selection = Self(rawValue: defaults.string(forKey: meetingKey) ?? "") ?? .parakeet
        return selection == .parakeetUltra ? .parakeet : selection
    }

    init(checkpoint: ParakeetCheckpoint) {
        self = checkpoint == .ultra ? .parakeetUltra : .parakeet
    }
}

@MainActor
enum LiveSpeechPurpose {
    case meeting
    case dictation

    func selectedEngine(in defaults: UserDefaults) -> LiveSpeechSelection {
        switch self {
        case .meeting: LiveSpeechSelection.meeting(defaults: defaults)
        case .dictation: LiveSpeechSelection.dictation(defaults: defaults)
        }
    }

    func language(in defaults: UserDefaults) -> String? {
        switch self {
        case .meeting:
            return MeetingLanguagePreferences.transcript(defaults: defaults).languageHint
        case .dictation:
            let value = defaults.string(forKey: DictationController.languageKey)
            return ["en", "es"].contains(value) ? value : nil
        }
    }
}
