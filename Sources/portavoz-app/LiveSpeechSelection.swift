import Foundation
import TranscriptionKit

/// This is a live-lane choice, not a replacement for the durable batch model.
/// Existing installations continue to use Parakeet unless they explicitly
/// select Apple's fixed-locale engine for one workflow.
enum LiveSpeechSelection: String, CaseIterable {
    case parakeet
    case appleSpeech

    static let meetingKey = "meetingLiveSpeechEngine"
    static let dictationKey = "dictationLiveSpeechEngine"

    static func meeting(defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: meetingKey) ?? "") ?? .parakeet
    }

    static func dictation(defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: dictationKey) ?? "") ?? .parakeet
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

enum LiveSpeechFailureMessage {
    static func dictation(_ error: Error) -> String {
        guard let readiness = error as? SpeechAnalyzerLiveReadiness else {
            return L10n.format("Dictation failed: %@", error.localizedDescription)
        }
        switch readiness {
        case .languageRequired:
            return L10n.text("Choose English or Spanish for Apple Speech in Dictation settings.")
        case .unavailable:
            return L10n.text("Apple Speech is unavailable. Choose Parakeet in Dictation settings.")
        case .unsupported:
            return L10n.text("Apple Speech does not support this language. Choose Parakeet in Dictation settings.")
        case .needsDownload:
            return L10n.text("Prepare the Apple Speech language asset in Dictation settings first.")
        case .ready:
            return L10n.text("Apple Speech could not start. Try Parakeet in Dictation settings.")
        }
    }
}
