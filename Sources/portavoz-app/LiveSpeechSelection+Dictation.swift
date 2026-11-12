import Foundation
import TranscriptionKit

// Dictation's side of the live-lane choice, apart from what meetings use.
extension LiveSpeechSelection {
    static let dictationKey = "dictationLiveSpeechEngine"
    static let dictationDefault = Self.parakeetUltra

    static func dictation(defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: dictationKey) ?? "") ?? dictationDefault
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
