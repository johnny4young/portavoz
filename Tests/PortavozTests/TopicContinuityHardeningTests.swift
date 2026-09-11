import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class TopicContinuityHardeningTests: XCTestCase {
    func testConfirmationRetryIsIdempotentAndIdentityReuseFailsClosed() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await TopicContinuityTests.seedMeeting(
            store,
            texts: ["The API design is established.", "API architecture continues."])
        let target = try await store.createTopicAndLink(TopicContinuityTests.proposal(
            meeting: seeded.meeting,
            segment: seeded.segments[0],
            label: "API design",
            language: "en",
            origin: .manual))
        let proposal = TopicContinuityTests.proposal(
            meeting: seeded.meeting,
            segment: seeded.segments[1],
            label: "API architecture",
            language: "en",
            origin: .generatedSimilarity,
            candidateTopicID: target.topic.id,
            confirmedAt: Date(timeIntervalSince1970: 1_783_695_800))

        let first = try await store.linkTopic(proposal, to: target.topic.id)
        let retry = try await store.linkTopic(proposal, to: target.topic.id)

        XCTAssertEqual(retry, first)
        let counts = try await TopicContinuityTests.topicCounts(store)
        XCTAssertEqual(counts, [2, 2, 2, 1])

        let reused = TopicLinkProposal(
            observedTopicID: proposal.observedTopicID,
            aliasID: proposal.aliasID,
            evidenceID: proposal.evidenceID,
            identityEventID: proposal.identityEventID,
            meetingID: proposal.meetingID,
            segmentID: proposal.segmentID,
            sourceTranscriptRevision: proposal.sourceTranscriptRevision,
            observedLabel: "Different identity",
            language: proposal.language,
            origin: proposal.origin,
            similarityCandidate: proposal.similarityCandidate,
            confirmedAt: proposal.confirmedAt)
        await XCTAssertThrowsTopicContinuityError {
            _ = try await store.linkTopic(reused, to: target.topic.id)
        }
        let afterReuseCounts = try await TopicContinuityTests.topicCounts(store)
        XCTAssertEqual(afterReuseCounts, counts)
    }

    func testConfirmedRetrySurvivesSourceCorrectionWithoutRewritingEvidence() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await TopicContinuityTests.seedMeeting(
            store,
            texts: ["The Atlas rollout remains on Friday."])
        let proposal = TopicContinuityTests.proposal(
            meeting: seeded.meeting,
            segment: seeded.segments[0],
            label: "Atlas rollout",
            language: "en",
            origin: .manual,
            confirmedAt: Date(timeIntervalSince1970: 1_783_695_850))
        let confirmed = try await store.createTopicAndLink(proposal)
        let correction = TranscriptCorrectionEvent(
            meetingID: seeded.meeting.id,
            baseTranscriptRevision: seeded.meeting.transcriptRevision,
            targetSegmentIDs: [seeded.segments[0].id],
            kind: .replaceText(text: "The Atlas rollout moved.", language: "en"),
            sourceDeviceID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_783_695_851))
        _ = try await store.appendTranscriptCorrection(correction)

        let retry = try await store.createTopicAndLink(proposal)

        XCTAssertEqual(retry.topic.id, confirmed.topic.id)
        XCTAssertEqual(retry.alias, confirmed.alias)
        XCTAssertEqual(retry.evidence.id, confirmed.evidence.id)
        XCTAssertEqual(retry.evidence.availability, .unavailable)
        let counts = try await TopicContinuityTests.topicCounts(store)
        XCTAssertEqual(counts, [1, 1, 1, 0])
    }

    func testGeneratedCandidateCannotSelectAnotherTopicOrInvalidScore() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await TopicContinuityTests.seedMeeting(
            store,
            texts: ["Topic one.", "Topic two.", "Generated candidate."])
        let first = try await store.createTopicAndLink(TopicContinuityTests.proposal(
            meeting: seeded.meeting,
            segment: seeded.segments[0],
            label: "Topic one",
            language: "en",
            origin: .manual))
        let second = try await store.createTopicAndLink(TopicContinuityTests.proposal(
            meeting: seeded.meeting,
            segment: seeded.segments[1],
            label: "Topic two",
            language: "en",
            origin: .manual))
        let candidate = TopicContinuityTests.proposal(
            meeting: seeded.meeting,
            segment: seeded.segments[2],
            label: "Candidate",
            language: "en",
            origin: .generatedSimilarity,
            candidateTopicID: first.topic.id)

        await XCTAssertThrowsTopicContinuityError {
            _ = try await store.linkTopic(candidate, to: second.topic.id)
        }
        let invalidScore = TopicLinkProposal(
            meetingID: seeded.meeting.id,
            segmentID: seeded.segments[2].id,
            sourceTranscriptRevision: seeded.meeting.transcriptRevision,
            observedLabel: "Candidate",
            language: "en",
            origin: .generatedSimilarity,
            similarityCandidate: TopicSimilarityCandidate(
                topicID: first.topic.id,
                similarity: 1.1,
                profileFingerprint: "semantic-profile-v1"))
        await XCTAssertThrowsTopicContinuityError {
            _ = try await store.createTopicAndLink(invalidScore)
        }
        let counts = try await TopicContinuityTests.topicCounts(store)
        XCTAssertEqual(counts, [2, 2, 2, 0])
    }

    func testExplicitMergeAndSplitPreserveEvidenceAndAppendHistory() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await TopicContinuityTests.seedMeeting(
            store,
            texts: ["Project Atlas is ready.", "Atlas rollout is next."])
        let source = try await store.createTopicAndLink(TopicContinuityTests.proposal(
            meeting: seeded.meeting,
            segment: seeded.segments[0],
            label: "Project Atlas",
            language: "en",
            origin: .manual))
        let target = try await store.createTopicAndLink(TopicContinuityTests.proposal(
            meeting: seeded.meeting,
            segment: seeded.segments[1],
            label: "Atlas rollout",
            language: "en",
            origin: .manual))

        let merge = try await store.mergeTopics(
            sourceTopicID: source.topic.id,
            into: target.topic.id)
        XCTAssertEqual(merge.source.mergedIntoTopicID, target.topic.id)
        let mergedCandidates = try await store.topics(matchingAlias: "Project Atlas")
        XCTAssertEqual(mergedCandidates.map(\.id), [target.topic.id])
        let mergedEvidence = try await store.topicEvidence(for: target.topic.id)
        XCTAssertEqual(mergedEvidence.map(\.segmentID), seeded.segments.map(\.id))

        await XCTAssertThrowsTopicContinuityError {
            _ = try await store.mergeTopics(
                sourceTopicID: target.topic.id,
                into: source.topic.id)
        }

        let split = try await store.splitTopic(
            sourceTopicID: source.topic.id,
            from: target.topic.id)
        XCTAssertNil(split.source.mergedIntoTopicID)
        let splitCandidates = try await store.topics(matchingAlias: "Project Atlas")
        XCTAssertEqual(splitCandidates.map(\.id), [source.topic.id])
        let splitEvidence = try await store.topicEvidence(for: source.topic.id)
        XCTAssertEqual(splitEvidence.map(\.segmentID), [seeded.segments[0].id])
        let history = try await store.topicIdentityHistory(for: source.topic.id)
        XCTAssertEqual(history.map(\.kind), [.merge, .split])

        await XCTAssertThrowsTopicContinuityError {
            try await store.database.write { database in
                try database.execute(
                    sql: "UPDATE topicIdentityEvent SET kind = 'merge' WHERE id = ?",
                    arguments: [split.event.id.rawValue.uuidString])
            }
        }
    }

    func testSchemaRejectsCrossTopicAliasAndContinuityRewrites() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await TopicContinuityTests.seedMeeting(
            store,
            texts: ["First topic.", "Second topic."])
        let first = try await store.createTopicAndLink(TopicContinuityTests.proposal(
            meeting: seeded.meeting,
            segment: seeded.segments[0],
            label: "First topic",
            language: "en",
            origin: .manual))
        let second = try await store.createTopicAndLink(TopicContinuityTests.proposal(
            meeting: seeded.meeting,
            segment: seeded.segments[1],
            label: "Second topic",
            language: "en",
            origin: .manual))

        await XCTAssertThrowsTopicContinuityError {
            try await store.database.write { database in
                try database.execute(
                    sql: "UPDATE topicAlias SET displayLabel = 'Changed' WHERE id = ?",
                    arguments: [first.alias.id.rawValue.uuidString])
            }
        }
        await XCTAssertThrowsTopicContinuityError {
            try await store.database.write { database in
                try database.execute(
                    sql: "UPDATE topicMeetingEvidence SET aliasID = ? WHERE id = ?",
                    arguments: [
                        second.alias.id.rawValue.uuidString,
                        first.evidence.id.rawValue.uuidString
                    ])
            }
        }
        let foreignKeysValid = try await store.database.read { database in
            try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty
        }
        XCTAssertTrue(foreignKeysValid)
    }

    func testIdentityEventRetriesAreIdempotentAndStrictlyOrdered() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await TopicContinuityTests.seedMeeting(
            store,
            texts: ["Project Atlas.", "Atlas rollout."])
        let source = try await store.createTopicAndLink(TopicContinuityTests.proposal(
            meeting: seeded.meeting,
            segment: seeded.segments[0],
            label: "Project Atlas",
            language: "en",
            origin: .manual))
        let target = try await store.createTopicAndLink(TopicContinuityTests.proposal(
            meeting: seeded.meeting,
            segment: seeded.segments[1],
            label: "Atlas rollout",
            language: "en",
            origin: .manual))
        let mergeID = TopicIdentityEventID()
        let requestedAt = Date(timeIntervalSince1970: 1_783_695_900.0004)

        let merge = try await store.mergeTopics(
            sourceTopicID: source.topic.id,
            into: target.topic.id,
            eventID: mergeID,
            at: requestedAt)
        let mergeRetry = try await store.mergeTopics(
            sourceTopicID: source.topic.id,
            into: target.topic.id,
            eventID: mergeID,
            at: requestedAt)
        XCTAssertEqual(mergeRetry.event, merge.event)

        let splitID = TopicIdentityEventID()
        let split = try await store.splitTopic(
            sourceTopicID: source.topic.id,
            from: target.topic.id,
            eventID: splitID,
            at: requestedAt)
        let splitRetry = try await store.splitTopic(
            sourceTopicID: source.topic.id,
            from: target.topic.id,
            eventID: splitID,
            at: requestedAt)
        XCTAssertEqual(splitRetry.event, split.event)
        XCTAssertGreaterThan(split.event.occurredAt, merge.event.occurredAt)
        let history = try await store.topicIdentityHistory(for: source.topic.id)
        XCTAssertEqual(history.map(\.kind), [.merge, .split])

        await XCTAssertThrowsTopicContinuityError {
            _ = try await store.splitTopic(
                sourceTopicID: source.topic.id,
                from: target.topic.id,
                eventID: mergeID,
                at: requestedAt)
        }
    }

}
