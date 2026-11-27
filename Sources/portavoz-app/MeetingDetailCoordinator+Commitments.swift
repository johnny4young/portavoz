import ApplicationKit
import Foundation
import PortavozCore

extension MeetingDetailCoordinator {
    /// The cards beside the transcript and the flows they reuse; nil without any.
    func marginContext(
        _ detail: MeetingReviewReadModel,
        notes: MeetingMarginNotes,
        focusEvidence: @escaping @MainActor (TranscriptSegment) -> Void
    ) -> MeetingMarginNotesContext? {
        guard !notes.byRow.isEmpty else { return nil }
        return MeetingMarginNotesContext(
            notes: notes,
            cast: detail.core.voiceCast,
            decisionConfirmations: model.state.decisionConfirmations,
            ownerChoices: detail.commitmentOwnerChoices(),
            confirmDecision: { presentDecisionConfirmation($0, statement: $1, meetingID: detail.meeting.id) },
            retractDecisionTopic: retractDecisionTopic,
            setDone: setActionItem,
            commitments: commitmentInboxActions(focusEvidence: focusEvidence))
    }

    func confirmCommitment(
        _ candidate: CommitmentInboxCandidate,
        title: String,
        assignee: CommitmentAssignee,
        dueAt: Date?
    ) async -> Bool {
        let effect = await model.send(.confirmCommitment(
            ConfirmMeetingCommitmentRequest(
                meetingID: meetingID,
                actionItemID: candidate.actionItem.id,
                title: title,
                assignee: assignee,
                dueAt: dueAt)))
        guard case .commitmentConfirmed = effect else { return false }
        return true
    }

    func dismissCommitment(_ candidate: CommitmentInboxCandidate) async -> Bool {
        await reviewCommitment(.dismiss(
            meetingID: meetingID,
            actionItemID: candidate.actionItem.id))
    }

    func deferCommitment(
        _ candidate: CommitmentInboxCandidate,
        until revisitAt: Date
    ) async -> Bool {
        await reviewCommitment(.deferUntil(
            meetingID: meetingID,
            actionItemID: candidate.actionItem.id,
            revisitAt: revisitAt))
    }

    private func reviewCommitment(
        _ request: ReviewMeetingCommitmentRequest
    ) async -> Bool {
        let effect = await model.send(.reviewCommitment(request))
        guard case .commitmentReviewSaved = effect else { return false }
        return true
    }
}
