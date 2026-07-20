import ApplicationKit
import Foundation

/// Presentation-side localization for ApplicationKit use-case errors. The
/// application layer stays presentation-independent: its `errorDescription`
/// strings are English developer text shared with the English-only CLI, so
/// the app maps the cases its surfaces can receive to catalog strings here
/// and falls back to `localizedDescription` for everything unmapped.
enum UseCaseErrorMessages {
    static func describe(_ error: any Error) -> String {
        switch error {
        case ManageLocalVoiceIdentityError.unsupportedEnrollmentSource:
            L10n.text("This voice enrollment source is unavailable.")
        case ManageLocalVoiceIdentityError.invalidCaptureDuration:
            L10n.text("Voice enrollment duration must be between 1 and 60 seconds.")
        case ManageLocalVoiceIdentityError.invalidSample:
            L10n.text("The voice sample is too short or invalid.")
        case ManageMeetingVoiceMemoryError.meetingNotFound:
            L10n.text("The meeting no longer exists.")
        case ManageMeetingVoiceMemoryError.namedSpeakerNotFound:
            L10n.text("Choose a named participant before remembering their voice.")
        case PostCaptureProcessingCapabilityError.audioUnavailable:
            L10n.text("The finalized capture audio is no longer available.")
        case RefineMeetingError.audioNotRetained, RefineMeetingError.audioUnavailable:
            L10n.text("This meeting has no stored audio.")
        case PublishMeetingActionItemsError.meetingOrSummaryNotFound:
            L10n.text("The meeting does not exist or has no summary.")
        case ExportMeetingDocumentError.meetingNotFound:
            L10n.text("The meeting could not be found.")
        default:
            error.localizedDescription
        }
    }
}
