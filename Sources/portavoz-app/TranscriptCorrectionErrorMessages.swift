import ApplicationKit
import Foundation

/// Presentation-side localization for focused transcript correction failures.
enum TranscriptCorrectionErrorMessages {
    static func describe(_ error: any Error) -> String {
        guard let error = error as? CorrectMeetingTranscriptError else {
            return error.localizedDescription
        }
        return switch error {
        case .invalidTarget:
            L10n.text("This transcript line no longer matches the accepted recording.")
        case .invalidText:
            L10n.text("Corrected transcript text must contain spoken content.")
        case .incompatibleStructuralCorrection:
            L10n.text("This line has a structural correction that must be reviewed first.")
        }
    }
}
