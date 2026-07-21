import Foundation
import PortavozCore

enum RecordingSystemCaptureHealth: Equatable {
    case healthy
    case stalled(secondsWithoutFrames: TimeInterval)
    case recovering(attempt: Int, secondsWithoutFrames: TimeInterval)
    case recovered
    case failed

    /// Compact-HUD copy stays aligned with the full recording surface. A
    /// terminal tap failure is not a long outage: the call may still be live,
    /// but Portavoz must tell the user to restart capture explicitly.
    var compactStatusMessageKey: String {
        switch self {
        case .recovered:
            "Remote audio capture recovered."
        case .failed:
            "Remote audio capture failed. Stop and start a new recording to avoid losing the call."
        case .healthy, .stalled, .recovering:
            "Remote audio interrupted"
        }
    }

    var shouldSuggestStop: Bool {
        switch self {
        case .stalled(let seconds), .recovering(_, let seconds):
            RecordingOutageNudgePolicy.shouldSuggestStop(
                secondsWithoutFrames: seconds)
        case .healthy, .recovered, .failed:
            false
        }
    }
}

extension RecordingController {
    /// Recovery never stops capture automatically. Once remote callbacks have
    /// been absent for two minutes, make the existing Stop action prominent:
    /// the call may have ended while Portavoz kept the microphone safe.
    var shouldSuggestStopForRemoteOutage: Bool {
        systemCaptureHealth.shouldSuggestStop
    }
}
