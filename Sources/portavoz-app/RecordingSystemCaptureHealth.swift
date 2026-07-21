import Foundation
import PortavozCore

enum RecordingSystemCaptureHealth: Equatable {
    case healthy
    case stalled(secondsWithoutFrames: TimeInterval)
    case recovering(attempt: Int, secondsWithoutFrames: TimeInterval)
    case recovered
    case failed
}

extension RecordingController {
    /// Recovery never stops capture automatically. Once remote callbacks have
    /// been absent for two minutes, make the existing Stop action prominent:
    /// the call may have ended while Portavoz kept the microphone safe.
    var shouldSuggestStopForRemoteOutage: Bool {
        switch systemCaptureHealth {
        case .stalled(let seconds), .recovering(_, let seconds):
            RecordingOutageNudgePolicy.shouldSuggestStop(
                secondsWithoutFrames: seconds)
        case .failed:
            true
        case .healthy, .recovered:
            false
        }
    }
}
