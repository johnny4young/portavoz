import ApplicationKit
import Foundation
import PortavozCore

extension AppServices {
    /// Real confirmation authority and the same disposable graph projection as
    /// production. The generated observation is fixed by the summary fixture;
    /// the user gesture creates one exact topic identity and decision link. A
    /// second source-backed decision remains deliberately unlinked to the topic;
    /// an explicit relationship to the linked successor still makes it a
    /// relevant conflict without weakening topic authority.
    func seedAskTopicMemoryIfRequested(
        meetingID: MeetingID,
        citedSegmentID: UUID
    ) async {
        guard usesTemporaryMeetingStore,
              ProcessInfo.processInfo.arguments.contains("-seed-ask-topic-memory")
        else {
            return
        }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_110)
        do {
            let replaced = try await seedAskTopicReplacedDecision(
                before: timestamp)
            let successor = try await ConfirmDecisionAboutTopic(store: store).execute(
                ConfirmDecisionAboutTopicRequest(
                    observationID: Self.seedDecisionObservationID,
                    meetingID: meetingID,
                    evidenceSegmentID: citedSegmentID,
                    sourceTranscriptRevision: 0,
                    topic: .labeled("model rollout"),
                    confirmedAt: timestamp))
            _ = try await ConfirmDecisionRelationship(store: store).execute(
                DecisionRelationshipConfirmation(
                    targetDecisionID: replaced,
                    successorDecisionID: successor.decisionID,
                    kind: .supersede,
                    eventID: Self.seedDecisionRelationshipEventID,
                    confirmedAt: timestamp.addingTimeInterval(10)))
            try await projectAskMemoryGraph(
                at: timestamp.addingTimeInterval(10),
                owner: "ui-test-ask-topic-memory")
        } catch {
            assertionFailure("Could not seed Ask topic memory: \(error)")
        }
    }

    private func seedAskTopicReplacedDecision(
        before timestamp: Date
    ) async throws -> DecisionID {
        let meeting = Meeting(
            id: Self.seedReplacedDecisionMeetingID,
            title: "Planning baseline",
            startedAt: Date(timeIntervalSince1970: 1_699_913_600),
            endedAt: Date(timeIntervalSince1970: 1_699_914_200),
            language: "es")
        try await store.save(meeting)
        let segment = TranscriptSegment(
            id: Self.seedReplacedDecisionSegmentID,
            meetingID: meeting.id,
            channel: .system,
            text: "El rollout del modelo quedaba para el jueves.",
            startTime: 4,
            endTime: 7,
            isFinal: true)
        try await store.save([segment])
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "es",
            markdown: """
                ## Decisiones
                - ▸ El rollout del modelo quedaba para el jueves.
                """,
            actionItems: [],
            decisionEvidence: [SummaryDecisionEvidence(
                id: Self.seedReplacedDecisionObservationID,
                sectionOrdinal: 0,
                bulletOrdinal: 0,
                evidenceSegmentIDs: [segment.id])]))
        return try await ConfirmDecisionAboutTopic(store: store).execute(
            ConfirmDecisionAboutTopicRequest(
                observationID: Self.seedReplacedDecisionObservationID,
                meetingID: meeting.id,
                evidenceSegmentID: segment.id,
                sourceTranscriptRevision: meeting.transcriptRevision,
                topic: .none,
                confirmedAt: timestamp.addingTimeInterval(-10)))
            .decisionID
    }

    private static let seedReplacedDecisionObservationID = SummaryDecisionID(rawValue: UUID(
        uuidString: "B5D40000-0000-4000-8000-000000000002")!)
    private static let seedReplacedDecisionMeetingID = MeetingID(rawValue: UUID(
        uuidString: "B5D40000-0000-4000-8000-000000000003")!)
    private static let seedReplacedDecisionSegmentID = UUID(
        uuidString: "B5D40000-0000-4000-8000-000000000004")!
    private static let seedDecisionRelationshipEventID = DecisionEventID(rawValue: UUID(
        uuidString: "B5D40000-0000-4000-8000-000000000005")!)
}
