import Foundation
import PortavozCore

enum PostCaptureProcessingError: LocalizedError {
    case emptyTranscript
    case inputNotReady
    case inputSuperseded
    /// A summary attempt whose durable input no longer matches the fingerprint
    /// it was fenced against, carrying the request that does match it. The
    /// stale attempt is cancelled and this replacement is admitted in the same
    /// transaction, so a drifted prediction costs a retry instead of the
    /// meeting's only automatic summary.
    case summaryInputSuperseded(replacement: ProcessingJobRequest)
    case meetingUnavailable
    case summaryProviderUnavailable
    case unsupportedKind(String)

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            "The captured meeting has no transcript to process."
        case .inputNotReady:
            "The processing input does not have final durable evidence."
        case .inputSuperseded, .summaryInputSuperseded:
            "The processing input changed before execution."
        case .meetingUnavailable:
            "The meeting is no longer available."
        case .summaryProviderUnavailable:
            "No configured local summary provider is currently available."
        case .unsupportedKind(let kind):
            "The process worker does not support \(kind)."
        }
    }
}
