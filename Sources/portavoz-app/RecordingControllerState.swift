import PortavozCore

enum RecordingFailureRecovery: Equatable {
    case retry
    case library
    case supportDiagnostics
}

struct RecordingFailureContext: Equatable {
    let code: String
    let category: FailureCategory
    let recovery: RecordingFailureRecovery
}

enum RecordingPhase: Equatable {
    case idle
    case preparing
    case recording
    case processing(String)
    case done(MeetingID)
    case failed(String)
}
