import Foundation
import PortavozCore

/// `-seed-radar-due-board` (with `-seed-commitment-radar`): work due today and
/// a suggestion put off to tomorrow, so Radar's board has every chip style.
extension AppServices {
    static let seedDueTodayCommitmentID = CommitmentID(rawValue: UUID(
        uuidString: "B5D50000-0000-4000-8000-000000000001")!)
    static let seedPutOffActionItemID = UUID(
        uuidString: "B5E00000-0000-4000-8000-000000000005")!

    static var seedsDueBoard: Bool {
        ProcessInfo.processInfo.arguments.contains("-seed-radar-due-board")
    }

    static func seedPutOffSuggestion(
        ownerID: SpeakerID,
        citedSegmentID: UUID
    ) -> (item: ActionItem, evidence: SummaryActionItemEvidence)? {
        guard seedsDueBoard else { return nil }
        return (
            ActionItem(id: seedPutOffActionItemID, text: "Share the pilot notes", ownerSpeakerID: ownerID),
            SummaryActionItemEvidence(actionItemID: seedPutOffActionItemID, evidenceSegmentIDs: [citedSegmentID]))
    }

    func seedDueBoardIfRequested(meetingID: MeetingID, now: Date) async throws {
        guard Self.seedsDueBoard else { return }
        let today = Calendar.autoupdatingCurrent.startOfDay(for: now)
        _ = try await store.confirmCommitment(
            CommitmentConfirmation(
                commitmentID: Self.seedDueTodayCommitmentID,
                title: "Ask infra for the permissions",
                assignee: .me,
                dueAt: today.addingTimeInterval(18 * 3_600),
                origin: .manual(meetingID: meetingID)),
            at: now.addingTimeInterval(-600))
        try await store.setCommitmentReviewDecision(
            .deferred,
            for: Self.seedPutOffActionItemID,
            meetingID: meetingID,
            revisitAt: today.addingTimeInterval(33 * 3_600),
            at: now)
    }
}
