import ApplicationKit
import PortavozCore

/// Only measured preparation progress is numeric. File/model phases are not a
/// fabricated total percentage, and stored diagnostic messages are never UI copy.
enum AudioImportQueuePresentation {
    /// `canRetry` is false once a cancelled or failed import retired its
    /// external source before any owned copy: only a new selection resumes it.
    static func status(_ job: ProcessingJob, phase: ImportMeetingProgress?, canRetry: Bool = true) -> String {
        switch job.state {
        case .pending: L10n.text("Waiting to import")
        case .cancelled:
            canRetry
                ? L10n.text("Cancelled — retry when you are ready")
                : L10n.text("Cancelled — import the file again to continue")
        case .succeeded: L10n.text("Ready")
        case .failed: canRetry ? failure(job.errorCode) : retiredFailure(job.errorCode)
        case .running: progress(phase)
        }
    }

    private static func retiredFailure(_ code: String?) -> String {
        switch code {
        case "import.source.changed":
            L10n.text("The original changed. Import it again as a new file.")
        case "import.source.unavailable":
            L10n.text("The original is unavailable. Reconnect its drive, then import it again.")
        default:
            L10n.text("The original could not be copied. Import it again.")
        }
    }

    private static func progress(_ phase: ImportMeetingProgress?) -> String {
        switch phase {
        case nil: L10n.text("Checking and copying audio…")
        case .preparingModels: L10n.text("Preparing models…")
        case .preparingWhisper(let size, let percent, let downloading):
            if downloading {
                L10n.format("Downloading Whisper %@… %lld%%", size, max(0, min(100, percent)))
            } else {
                L10n.text("Loading Whisper…")
            }
        case .transcribing: L10n.text("Transcribing…")
        case .identifyingSpeakers: L10n.text("Identifying speakers…")
        case .generatingSummary: L10n.text("Generating summary…")
        }
    }

    private static func failure(_ code: String?) -> String {
        switch code {
        case "import.source.changed":
            L10n.text("The original changed. Import it again as a new file.")
        case "import.source.unavailable":
            L10n.text("The original is unavailable. Reconnect its drive, then retry.")
        case "import.copy.invalid":
            L10n.text("The retained copy could not be verified. Import the original again.")
        case "import.copy.busy":
            L10n.text("Another audio operation is finishing. Retry shortly.")
        default:
            L10n.text("Processing failed. Check model readiness and available storage, then retry.")
        }
    }
}
