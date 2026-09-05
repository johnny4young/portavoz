import ApplicationKit
import Foundation

/// Presentation-side localization for focused transcript correction failures.
enum TranscriptCorrectionErrorMessages {
    static func describe(_ error: any Error) -> String {
        if let error = error as? CorrectMeetingTranscriptError {
            return describe(error)
        }
        if let error = error as? RestructureMeetingTranscriptError {
            return describe(error)
        }
        return error.localizedDescription
    }

    private static func describe(_ error: CorrectMeetingTranscriptError) -> String {
        return switch error {
        case .invalidTarget:
            L10n.text("This transcript line no longer matches the accepted recording.")
        case .invalidText:
            L10n.text("Corrected transcript text must contain spoken content.")
        case .incompatibleStructuralCorrection:
            L10n.text("This line has a structural correction that must be reviewed first.")
        }
    }

    private static func describe(_ error: RestructureMeetingTranscriptError) -> String {
        return switch error {
        case .invalidAcceptedTranscript:
            L10n.text("The accepted transcript cannot be edited safely.")
        case .staleTranscript:
            L10n.text("The transcript changed before this correction was saved.")
        case .invalidTarget:
            L10n.text("The selected transcript line is no longer available.")
        case .invalidSplit:
            L10n.text("A split needs two spoken parts and a time inside the selected line.")
        case .invalidMerge:
            L10n.text("Only adjacent lines from the same speaker and audio channel can be merged.")
        case .incompatibleCorrection:
            L10n.text("Undo the existing correction before changing this line's structure.")
        case .correctionNoLongerActive:
            L10n.text("This structural correction has already been restored or replaced.")
        }
    }
}
