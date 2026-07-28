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

/// The pull-based live-assist entry points, colocated with the extracted
/// state types to keep the controller file inside its size budget. Both
/// delegate to concern models that own their own lifecycle.
extension RecordingController {
    var canReturnToLiveSession: Bool {
        switch phase {
        case .preparing, .recording, .processing:
            true
        case .idle, .done, .failed:
            false
        }
    }

    func requestCatchUp() {
        catchUp.request(
            captions: captions,
            meetingID: meetingID,
            vocabulary: vocabulary
        ) { [weak self] in self?.phase == .recording }
    }

    func requestNextQuestion() {
        nextQuestion.request(
            captions: captions,
            meetingID: meetingID,
            pendingObjectives: objectives.pending.map(\.text),
            vocabulary: vocabulary
        ) { [weak self] in self?.phase == .recording }
    }
}
