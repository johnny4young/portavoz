import Foundation
import IntelligenceKit
import Observation
import PortavozCore

/// Pre-meeting objectives with live check-off (the Otter Live
/// Assist pattern reimplemented local-first). Manual changes need no AI;
/// the controller commits them before updating this presentation model.
/// The AUTOMATIC check-off rides the rolling tick and is Apuntador work:
/// gated by the same opt-in, and conservative by construction — the model
/// can only check objectives, never uncheck, and only from the offered
/// pending list.
@MainActor
@Observable
final class RecordingObjectivesModel {
    typealias Check = @MainActor ([String], [TranscriptSegment]) async -> [Int]
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
    private(set) var revision = 0
    private(set) var admissionIssue: AdmissionIssue?
    @ObservationIgnored private let check: Check

    init(check: @escaping Check = { objectives, window in
        guard #available(macOS 26.0, *) else { return [] }
        return await ObjectiveCheckDetector.addressedIndexes(objectives: objectives, window: window)
    }) {
        self.check = check
    }

    var pending: [LiveObjective] { objectives.filter { $0.checkedAt == nil } }

    func proposedAdditions(_ texts: [String]) -> [LiveObjective] {
        admissionIssue = nil
        var proposed: [LiveObjective] = []
        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.count <= Self.maximumObjectiveCharacters,
                  trimmed.utf8.count <= Self.maximumObjectiveUTF8Bytes else {
                admissionIssue = .tooLong
                return []
            }
            guard !(objectives + proposed).contains(where: {
                $0.text.compare(trimmed, options: [.caseInsensitive]) == .orderedSame
            }) else { continue }
            guard objectives.count + proposed.count < Self.maximumObjectives else {
                admissionIssue = .limitReached
                return []
            }
            proposed.append(LiveObjective(text: trimmed))
        }
        return proposed
    }

    func accept(_ objective: LiveObjective) {
        revision += 1
        if let index = objectives.firstIndex(where: { $0.id == objective.id }) {
            objectives[index] = objective
        } else {
            objectives.append(objective)
        }
        admissionIssue = nil
    }

    func remove(_ id: LiveObjective.ID) {
        revision += 1
        objectives.removeAll { $0.id == id }
        if objectives.count < Self.maximumObjectives {
            admissionIssue = nil
        }
    }

    func proposedToggle(_ id: LiveObjective.ID, elapsed: TimeInterval) -> LiveObjective? {
        guard var objective = objectives.first(where: { $0.id == id }) else { return nil }
        objective.checkedAt = objective.checkedAt == nil ? max(0, elapsed) : nil
        objective.checkedByModel = false
        return objective
    }

    /// One automatic pass over the recent window. Runs inline on the
    /// caller's rolling tick — the detector already schedules its model
    /// call at `.background`, so this never competes with interactive work.
    func automaticChanges(
        captions: [TranscriptSegment],
        elapsed: TimeInterval
    ) async -> [LiveObjective] {
        let offeredRevision = revision
        let offered = pending
        let pendingTexts = offered.map(\.text)
        let window = ObjectiveCheckPolicy.clip(captions)
        guard ObjectiveCheckPolicy.shouldRun(
            pendingObjectives: pendingTexts.count,
            clippedRows: window.count)
        else { return [] }
        let addressed = Set(await check(pendingTexts, window))
        guard !Task.isCancelled, revision == offeredRevision, !addressed.isEmpty else { return [] }
        return offered.enumerated().compactMap { index, offeredObjective in
            guard addressed.contains(index),
                  let current = objectives.first(where: { $0.id == offeredObjective.id }),
                  current == offeredObjective
            else { return nil }
            var checked = current
            checked.checkedAt = max(0, elapsed)
            checked.checkedByModel = true
            return checked
        }
    }

    /// The same stable context identities used during capture and at Stop.
    /// Check-off state folds into content so the summary sees what was covered and what
    /// remained open, without any schema change.
    func contextItems(meetingID: MeetingID) -> [ContextItem] {
        objectives.map { $0.contextItem(meetingID: meetingID) }
    }

    func reset() {
        revision += 1
        objectives = []
        admissionIssue = nil
    }
}

extension RecordingObjectivesModel.LiveObjective {
    func contextItem(meetingID: MeetingID) -> ContextItem {
        ContextItem(id: id, meetingID: meetingID, kind: .objective,
                    content: checkedAt == nil ? text : "\u{2713} " + text,
                    timestamp: checkedAt ?? 0)
    }
}
