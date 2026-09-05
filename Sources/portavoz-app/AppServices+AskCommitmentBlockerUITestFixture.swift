import ApplicationKit
import Foundation
import PortavozCore

extension AppServices {
    /// Real confirmation authority plus one disposable graph projection for
    /// the exact person → commitment → blocker XCUITest journey. Production
    /// launches can never create this synthetic decision or causal link.
    func seedAskMemoryIfRequested(
        canonicalPersonID: PersonID?,
        audioDirectory: String?
    ) async {
        guard usesTemporaryMeetingStore,
              ProcessInfo.processInfo.arguments.contains("-seed-ask-memory")
        else {
            return
        }
        guard let canonicalPersonID else {
            assertionFailure("Could not seed Ask memory's canonical person")
            return
        }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_200)
        do {
            _ = try await store.confirmCommitment(
                CommitmentConfirmation(
                    commitmentID: Self.askMemoryCommitmentID,
                    sourceID: Self.askMemorySourceID,
                    eventID: Self.askMemoryEventID,
                    title: "Prepare the rollout",
                    assignee: .person(canonicalPersonID),
                    origin: .generatedActionItem(Self.seedActionItemID)),
                at: timestamp)
            let decisionID = try await seedAskMemoryBlockerDecision(
                before: timestamp,
                audioDirectory: audioDirectory)
            _ = try await ConfirmDecisionCommitmentBlocker(store: store).execute(
                DecisionCommitmentBlockerConfirmation(
                    blockerID: Self.askMemoryBlockerID,
                    decisionID: decisionID,
                    commitmentID: Self.askMemoryCommitmentID,
                    evidence: DecisionCommitmentBlockerEvidence(
                        meetingID: Self.askMemoryBlockerMeetingID,
                        sourceTranscriptRevision: 0,
                        segmentIDs: [Self.askMemoryBlockerSegmentID]),
                    confirmedAt: timestamp))
            try await projectAskMemoryGraph(
                at: timestamp,
                owner: "ui-test-ask-memory")
        } catch {
            assertionFailure("Could not seed Ask memory: \(error)")
        }
    }

    private func seedAskMemoryBlockerDecision(
        before timestamp: Date,
        audioDirectory: String?
    ) async throws -> DecisionID {
        let meeting = Meeting(
            id: Self.askMemoryBlockerMeetingID,
            title: "Security review",
            startedAt: Date(timeIntervalSince1970: 1_700_000_150),
            endedAt: Date(timeIntervalSince1970: 1_700_000_450),
            language: "es",
            audioDirectory: audioDirectory)
        try await store.save(meeting)
        let segment = TranscriptSegment(
            id: Self.askMemoryBlockerSegmentID,
            meetingID: meeting.id,
            channel: .system,
            text: "La revisión de seguridad debe aprobarse antes del rollout.",
            startTime: 4,
            endTime: 9,
            isFinal: true)
        try await store.save([segment])
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "es",
            markdown: """
                ## Decisiones
                - ▸ La revisión de seguridad debe aprobarse antes del rollout.
                """,
            actionItems: [],
            decisionEvidence: [SummaryDecisionEvidence(
                id: Self.askMemoryBlockerObservationID,
                sectionOrdinal: 0,
                bulletOrdinal: 0,
                evidenceSegmentIDs: [segment.id])]))
        let decision = try await ConfirmObservedDecision(store: store).execute(
            DecisionConfirmation(
                decisionID: Self.askMemoryBlockerDecisionID,
                sourceID: Self.askMemoryBlockerDecisionSourceID,
                eventID: Self.askMemoryBlockerDecisionEventID,
                observationID: Self.askMemoryBlockerObservationID,
                confirmedAt: timestamp.addingTimeInterval(-10)))
        return decision.decision.id
    }

    private static let askMemoryCommitmentID = CommitmentID(rawValue: UUID(
        uuidString: "B5D10000-0000-4000-8000-000000000005")!)
    private static let askMemorySourceID = CommitmentSourceID(rawValue: UUID(
        uuidString: "B5D20000-0000-4000-8000-000000000005")!)
    private static let askMemoryEventID = CommitmentEventID(rawValue: UUID(
        uuidString: "B5D30000-0000-4000-8000-000000000008")!)
    private static let askMemoryBlockerMeetingID = MeetingID(rawValue: UUID(
        uuidString: "B5D50000-0000-4000-8000-000000000001")!)
    private static let askMemoryBlockerSegmentID = UUID(
        uuidString: "B5D50000-0000-4000-8000-000000000002")!
    private static let askMemoryBlockerObservationID = SummaryDecisionID(rawValue: UUID(
        uuidString: "B5D50000-0000-4000-8000-000000000003")!)
    private static let askMemoryBlockerDecisionID = DecisionID(rawValue: UUID(
        uuidString: "B5D50000-0000-4000-8000-000000000004")!)
    private static let askMemoryBlockerDecisionSourceID = DecisionSourceID(rawValue: UUID(
        uuidString: "B5D50000-0000-4000-8000-000000000005")!)
    private static let askMemoryBlockerDecisionEventID = DecisionEventID(rawValue: UUID(
        uuidString: "B5D50000-0000-4000-8000-000000000006")!)
    private static let askMemoryBlockerID = DecisionCommitmentBlockerID(rawValue: UUID(
        uuidString: "B5D50000-0000-4000-8000-000000000007")!)
}
