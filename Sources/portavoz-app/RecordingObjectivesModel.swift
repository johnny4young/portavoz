import Foundation
import IntelligenceKit
import Observation
import PortavozCore

/// Pre-meeting objectives with live check-off (the Otter Live
/// Assist pattern reimplemented local-first). The checklist itself is pure
/// UI state — adding and manually toggling objectives never needs a model.
/// The AUTOMATIC check-off rides the rolling tick and is Apuntador work:
/// gated by the same opt-in, and conservative by construction — the model
/// can only check objectives, never uncheck, and only from the offered
/// pending list.
@MainActor
@Observable
final class RecordingObjectivesModel {
    static let maximumObjectives = 8
    static let maximumObjectiveCharacters = 280
    static let maximumObjectiveUTF8Bytes = 2_048

    enum AdmissionIssue: Equatable {
        case tooLong
        case limitReached
    }

    struct LiveObjective: Identifiable, Equatable {
        let id = UUID()
        var text: String
        /// Seconds since recording start when it was checked; nil = pending.
        var checkedAt: TimeInterval?
        /// True when the model checked it (rendered with the AI spark);
        /// manual toggles always reset this.
        var checkedByModel = false
    }

    private(set) var objectives: [LiveObjective] = []
    private(set) var admissionIssue: AdmissionIssue?

    var pending: [LiveObjective] { objectives.filter { $0.checkedAt == nil } }

    func add(_ text: String) {
        admissionIssue = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.count <= Self.maximumObjectiveCharacters,
              trimmed.utf8.count <= Self.maximumObjectiveUTF8Bytes
        else {
            admissionIssue = .tooLong
            return
        }
        // Re-adding an existing objective is a no-op, not a duplicate row.
        guard !objectives.contains(where: {
            $0.text.compare(trimmed, options: [.caseInsensitive]) == .orderedSame
        }) else { return }
        guard objectives.count < Self.maximumObjectives else {
            admissionIssue = .limitReached
            return
        }
        objectives.append(LiveObjective(text: trimmed))
        admissionIssue = nil
    }

    func remove(_ id: LiveObjective.ID) {
        objectives.removeAll { $0.id == id }
        if objectives.count < Self.maximumObjectives {
            admissionIssue = nil
        }
    }

    func toggle(_ id: LiveObjective.ID, elapsed: TimeInterval) {
        guard let index = objectives.firstIndex(where: { $0.id == id }) else { return }
        if objectives[index].checkedAt == nil {
            objectives[index].checkedAt = max(0, elapsed)
        } else {
            objectives[index].checkedAt = nil
        }
        objectives[index].checkedByModel = false
    }

    /// One automatic pass over the recent window. Runs inline on the
    /// caller's rolling tick — the detector already schedules its model
    /// call at `.background`, so this never competes with interactive work.
    func runAutomaticCheck(
        captions: [TranscriptSegment],
        elapsed: TimeInterval
    ) async {
        guard #available(macOS 26.0, *) else { return }
        let pendingTexts = pending.map(\.text)
        let window = ObjectiveCheckPolicy.clip(captions)
        guard ObjectiveCheckPolicy.shouldRun(
            pendingObjectives: pendingTexts.count,
            clippedRows: window.count)
        else { return }
        let addressed = await ObjectiveCheckDetector.addressedIndexes(
            objectives: pendingTexts,
            window: window)
        guard !Task.isCancelled, !addressed.isEmpty else { return }
        let addressedTexts = Set(addressed.map { pendingTexts[$0] })
        for index in objectives.indices
        where objectives[index].checkedAt == nil
            && addressedTexts.contains(objectives[index].text) {
            objectives[index].checkedAt = max(0, elapsed)
            objectives[index].checkedByModel = true
        }
    }

    /// The objectives as D28 context for Stop: check-off state folds into
    /// the content so the summary prompt sees what was covered and what
    /// remained open, without any schema change.
    func contextItems(meetingID: MeetingID) -> [ContextItem] {
        objectives.map { objective in
            ContextItem(
                meetingID: meetingID,
                kind: .objective,
                content: objective.checkedAt == nil
                    ? objective.text
                    : "\u{2713} " + objective.text,
                timestamp: objective.checkedAt ?? 0)
        }
    }

    func reset() {
        objectives = []
        admissionIssue = nil
    }
}
