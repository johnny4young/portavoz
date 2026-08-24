import Foundation
import IntelligenceKit
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

    func setProactiveAssistEnabled(_ enabled: Bool) {
        guard phase == .recording else { return }
        proactiveAssist.setEnabled(
            enabled,
            captions: captions,
            pendingObjectives: proactiveObjectives)
    }

    func setProactiveAssistPaused(_ paused: Bool) {
        guard phase == .recording else { return }
        proactiveAssist.setPaused(
            paused,
            captions: captions,
            pendingObjectives: proactiveObjectives)
    }

    func observeProactiveAssist() {
        guard phase == .recording else { return }
        proactiveAssist.observe(
            captions: captions,
            pendingObjectives: proactiveObjectives)
    }

    func dismissProactiveSuggestion(_ id: ProactiveAssistSuggestion.ID) {
        proactiveAssist.dismiss(id)
    }

    func addObjective(_ text: String) {
        objectives.add(text)
        observeProactiveAssist()
    }

    func toggleObjective(_ id: UUID) {
        objectives.toggle(
            id,
            elapsed: Date().timeIntervalSince(startedAt))
        observeProactiveAssist()
    }

    func removeObjective(_ id: UUID) {
        objectives.remove(id)
        observeProactiveAssist()
    }

    private var proactiveObjectives: [ProactiveAssistObjective] {
        objectives.pending.map {
            ProactiveAssistObjective(id: $0.id, text: $0.text)
        }
    }
}
