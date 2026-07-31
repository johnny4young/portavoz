import Foundation

enum PostCaptureProcessingError: LocalizedError {
    case emptyTranscript
    case inputNotReady
    case inputSuperseded
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
