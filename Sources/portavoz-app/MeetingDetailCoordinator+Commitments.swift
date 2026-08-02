import ApplicationKit
import Foundation
import PortavozCore

extension MeetingDetailCoordinator {
    func confirmCommitment(
        _ candidate: CommitmentInboxCandidate,
        title: String,
        ownerID: PersonID?,
        dueAt: Date?
    ) async -> Bool {
        let effect = await model.send(.confirmCommitment(
            ConfirmMeetingCommitmentRequest(
                meetingID: meetingID,
                actionItemID: candidate.actionItem.id,
                title: title,
                canonicalPersonID: ownerID,
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
