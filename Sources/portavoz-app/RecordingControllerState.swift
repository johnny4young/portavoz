import Foundation
import IntelligenceKit
import PortavozCore
import TranscriptionKit

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
    /// User-defined terms shared by live assistance and transcription hints.
    var vocabulary: [String] {
        VocabularyPrompt.parse(UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
    }

    var canReturnToLiveSession: Bool {
        if hasPendingInputStop { return true }
        return switch phase {
        case .preparing, .recording, .processing:
            true
        case .idle, .done, .failed:
            false
        }
    }

    func requestCatchUp() {
        guard phase == .recording else { return }
        nextQuestion.dismiss()
        catchUp.request(
            captions: captions,
            meetingID: meetingID,
            vocabulary: vocabulary
        ) { [weak self] in self?.phase == .recording }
    }

    func requestNextQuestion() {
        guard phase == .recording else { return }
        catchUp.dismiss()
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
        addObjectives([text])
    }

    func addObjectives(_ texts: [String]) {
        guard phase == .recording, let writer = recordingInputWriter else { return }
        let additions = objectives.proposedAdditions(texts)
        guard !additions.isEmpty else { return }
        let sourceMeetingID = meetingID
        inputPersistence.enqueue(text: additions.map(\.text).joined(separator: "\n")) { [weak self] in
            guard let self,
                  self.objectives.proposedAdditions(additions.map(\.text)).count == additions.count else { return }
            try await writer.execute(meetingID: sourceMeetingID,
                                     items: additions.map { $0.contextItem(meetingID: sourceMeetingID) })
            for objective in additions { self.objectives.accept(objective) }
            if additions.count == 1,
               self.drafts.objective.trimmingCharacters(in: .whitespacesAndNewlines) == additions[0].text {
                self.drafts.objective = ""
            }
            self.observeProactiveAssist()
        }
    }

    func toggleObjective(_ id: UUID) {
        guard phase == .recording, let writer = recordingInputWriter else { return }
        let sourceMeetingID = meetingID
        let elapsed = max(0, Date().timeIntervalSince(startedAt))
        inputPersistence.enqueue { [weak self] in
            guard let self, let objective = self.objectives.proposedToggle(id, elapsed: elapsed) else { return }
            try await writer.execute(meetingID: sourceMeetingID,
                                     items: [objective.contextItem(meetingID: sourceMeetingID)])
            self.objectives.accept(objective)
            self.observeProactiveAssist()
        }
    }

    func removeObjective(_ id: UUID) {
        guard phase == .recording, let writer = recordingInputWriter else { return }
        let sourceMeetingID = meetingID
        inputPersistence.enqueue { [weak self] in
            try await writer.execute(meetingID: sourceMeetingID, removing: [id])
            self?.objectives.remove(id)
            self?.observeProactiveAssist()
        }
    }

    func persistAutomaticObjectives(
        _ changes: [RecordingObjectivesModel.LiveObjective], expectedRevision: Int
    ) {
        guard !changes.isEmpty, !inputPersistence.hasFailure, !inputPersistence.isSaving,
              let writer = recordingInputWriter else { return }
        let sourceMeetingID = meetingID
        inputPersistence.enqueue { [weak self] in
            guard let self, self.objectives.revision == expectedRevision else { return }
            let accepted = changes.filter { candidate in
                self.objectives.objectives.contains {
                    $0.id == candidate.id && $0.text == candidate.text && $0.checkedAt == nil
                }
            }
            guard !accepted.isEmpty else { return }
            try await writer.execute(meetingID: sourceMeetingID,
                                     items: accepted.map { $0.contextItem(meetingID: sourceMeetingID) })
            for objective in accepted { self.objectives.accept(objective) }
            self.observeProactiveAssist()
        }
    }

    private var proactiveObjectives: [ProactiveAssistObjective] {
        objectives.pending.map {
            ProactiveAssistObjective(id: $0.id, text: $0.text)
        }
    }
}

/// Unsubmitted editor input shares the active recording's lifetime, not a tab's.
struct RecordingDrafts {
    var note = ""
    var objective = ""
}
