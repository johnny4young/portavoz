import Foundation
import PortavozCore

enum PostCaptureProcessingError: LocalizedError {
    case emptyTranscript
    case inputNotReady
    /// An attempt whose durable input no longer matches the fingerprint it was
    /// fenced against, carrying the request that does match it. The stale
    /// attempt is cancelled and this replacement is admitted in the same
    /// transaction, so a drifted prediction costs a retry instead of the
    /// meeting's transcript, diarization, or only automatic summary.
    ///
    /// Every lane states its replacement. A `nil` is a deliberate claim that no
    /// request can be built from durable rows — cancelling without one lets
    /// StorageKit see a job list with no failure and flip the meeting to
    /// `ready` while the work it owed was never done.
    case inputSuperseded(replacement: ProcessingJobRequest?)
    case meetingUnavailable
    case summaryProviderUnavailable
    case unsupportedKind(String)

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            "The captured meeting has no transcript to process."
        case .inputNotReady:
            "The processing input does not have final durable evidence."
        case .inputSuperseded:
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
