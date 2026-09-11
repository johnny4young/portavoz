import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import StorageKit

/// The composed gesture: promote one generated decision observation to durable
/// truth and optionally assert what it is about — against the real store, so
/// every authority rule underneath stays load-bearing.
final class ConfirmDecisionAboutTopicTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testConfirmingWithANewLabelCreatesTheTopicAndLinks() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await seedObservation(in: store)

        let outcome = try await ConfirmDecisionAboutTopic(store: store).execute(
            ConfirmDecisionAboutTopicRequest(
                observationID: seeded.observationID,
                meetingID: seeded.meeting.id,
                evidenceSegmentID: seeded.segments[0].id,
                sourceTranscriptRevision: seeded.meeting.transcriptRevision,
                topic: .labeled("  atlas-500  "),
                confirmedAt: baseDate.addingTimeInterval(60)))

        XCTAssertEqual(outcome.topicLabel, "atlas-500", "trimmed exactly once")
        let states = try await store.decisionObservationConfirmations(
            for: [seeded.observationID])
        XCTAssertEqual(states.map(\.topicLabels), [["atlas-500"]])
        XCTAssertEqual(states.first?.decisionID, outcome.decisionID)
    }

    /// Re-running the gesture on an already confirmed observation reuses the
    /// decision instead of failing, so a topic can be added later.
    func testAddingATopicLaterReusesTheExistingDecision() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await seedObservation(in: store)
        let useCase = ConfirmDecisionAboutTopic(store: store)
        let first = try await useCase.execute(ConfirmDecisionAboutTopicRequest(
            observationID: seeded.observationID,
            meetingID: seeded.meeting.id,
            evidenceSegmentID: seeded.segments[0].id,
            sourceTranscriptRevision: seeded.meeting.transcriptRevision,
            topic: .none,
            confirmedAt: baseDate.addingTimeInterval(60)))

        let second = try await useCase.execute(ConfirmDecisionAboutTopicRequest(
            observationID: seeded.observationID,
            meetingID: seeded.meeting.id,
            evidenceSegmentID: seeded.segments[0].id,
            sourceTranscriptRevision: seeded.meeting.transcriptRevision,
            topic: .labeled("atlas-500"),
            confirmedAt: baseDate.addingTimeInterval(120)))

        XCTAssertEqual(first.decisionID, second.decisionID)
        XCTAssertEqual(second.topicLabel, "atlas-500")
    }

    func testATypedLabelMatchingAnExistingTopicLinksInsteadOfDuplicating() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await seedObservation(in: store)
        let existing = try await store.createTopicAndLink(TopicLinkProposal(
            meetingID: seeded.meeting.id,
            segmentID: seeded.segments[0].id,
            sourceTranscriptRevision: seeded.meeting.transcriptRevision,
            observedLabel: "atlas-500",
            language: "en",
            origin: .manual))

        let outcome = try await ConfirmDecisionAboutTopic(store: store).execute(
            ConfirmDecisionAboutTopicRequest(
                observationID: seeded.observationID,
                meetingID: seeded.meeting.id,
                evidenceSegmentID: seeded.segments[0].id,
                sourceTranscriptRevision: seeded.meeting.transcriptRevision,
                topic: .labeled("atlas-500"),
                confirmedAt: baseDate.addingTimeInterval(60)))

        let topics = try await store.linkableTopics()
        XCTAssertEqual(
            topics.filter { $0.preferredLabel == "atlas-500" }.count,
            1,
            "the typed label reuses the existing topic")
        XCTAssertEqual(outcome.topicLabel, existing.topic.preferredLabel)
    }

    /// An ambiguous label refuses rather than guessing which topic the user
    /// meant — identity is never resolved by the gesture.
    func testAnAmbiguousLabelRefusesWithoutConfirmingALink() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await seedObservation(in: store)
        for label in ["Atlas Rollout", "atlas   rollout"] {
            _ = try await store.createTopicAndLink(TopicLinkProposal(
                meetingID: seeded.meeting.id,
                segmentID: seeded.segments[0].id,
                sourceTranscriptRevision: seeded.meeting.transcriptRevision,
                observedLabel: label,
                language: "en",
                origin: .manual))
        }

        do {
            _ = try await ConfirmDecisionAboutTopic(store: store).execute(
                ConfirmDecisionAboutTopicRequest(
                    observationID: seeded.observationID,
                    meetingID: seeded.meeting.id,
                    evidenceSegmentID: seeded.segments[0].id,
                    sourceTranscriptRevision: seeded.meeting.transcriptRevision,
                    topic: .labeled("atlas rollout"),
                    confirmedAt: baseDate.addingTimeInterval(60)))
            XCTFail("an ambiguous label must refuse")
        } catch let error as ConfirmDecisionAboutTopicError {
            XCTAssertEqual(error, .ambiguousTopicLabel("atlas rollout"))
        }
        // The decision itself was still confirmed; only the link refused.
        let states = try await store.decisionObservationConfirmations(
            for: [seeded.observationID])
        XCTAssertEqual(states.map(\.topicLabels), [[]])
    }

    private func seedObservation(
        in store: MeetingStore
    ) async throws -> DecisionContinuityTests.SeededObservation {
        try await DecisionContinuityTests.seedObservation(
            store,
            statement: "Ship atlas-500 behind the flag.",
            evidenceTexts: ["We ship atlas-500 behind the flag."],
            startedAt: baseDate,
            summaryCreatedAt: baseDate.addingTimeInterval(10))
    }
}
