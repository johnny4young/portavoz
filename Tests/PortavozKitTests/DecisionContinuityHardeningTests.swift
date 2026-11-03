import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class DecisionContinuityHardeningTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_786_100_000)

    func testCorrectionRejectsNewConfirmationWithoutPartialRows() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await DecisionContinuityTests.seedObservation(
            store,
            statement: "Ship on Friday.",
            evidenceTexts: ["The rollout stays on Friday."],
            startedAt: baseDate)
        let correction = TranscriptCorrectionEvent(
            meetingID: seeded.meeting.id,
            baseTranscriptRevision: seeded.meeting.transcriptRevision,
            targetSegmentIDs: seeded.segments.map(\.id),
            kind: .replaceText(text: "The rollout moved.", language: "en"),
            sourceDeviceID: UUID(),
            createdAt: baseDate.addingTimeInterval(1))
        _ = try await store.appendTranscriptCorrection(correction)

        let observation = try await store.decisionObservation(for: seeded.observationID)
        XCTAssertEqual(observation.availability, .unavailable)
        await XCTAssertThrowsDecisionContinuityError {
            _ = try await store.confirmDecision(DecisionConfirmation(
                observationID: seeded.observationID,
                confirmedAt: self.baseDate.addingTimeInterval(2)))
        }
        let counts = try await DecisionContinuityTests.decisionCounts(store)
        XCTAssertEqual(counts, [0, 0, 0, 0])
    }

    func testExactRetrySurvivesCorrectionAndReturnsUnavailableEvidence() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await DecisionContinuityTests.seedObservation(
            store,
            statement: "Ship on Friday.",
            evidenceTexts: ["The rollout stays on Friday."],
            startedAt: baseDate)
        let confirmation = DecisionConfirmation(
            observationID: seeded.observationID,
            confirmedAt: baseDate.addingTimeInterval(2))
        let first = try await store.confirmDecision(confirmation)
        let correction = TranscriptCorrectionEvent(
            meetingID: seeded.meeting.id,
            baseTranscriptRevision: seeded.meeting.transcriptRevision,
            targetSegmentIDs: seeded.segments.map(\.id),
            kind: .replaceText(text: "The rollout moved.", language: "en"),
            sourceDeviceID: UUID(),
            createdAt: baseDate.addingTimeInterval(3))
        _ = try await store.appendTranscriptCorrection(correction)

        let retry = try await store.confirmDecision(confirmation)

        XCTAssertEqual(retry.decision, first.decision)
        XCTAssertEqual(retry.events, first.events)
        XCTAssertEqual(retry.sources.map(\.availability), [.unavailable])
        let counts = try await DecisionContinuityTests.decisionCounts(store)
        XCTAssertEqual(counts, [1, 1, 1, 1])
    }

    func testIdentityReuseFailsClosedAndLeavesOriginalAggregate() async throws {
        let store = try MeetingStore.inMemory()
        let first = try await DecisionContinuityTests.seedObservation(
            store,
            statement: "Use API A.",
            evidenceTexts: ["API A was selected."],
            startedAt: baseDate)
        let second = try await DecisionContinuityTests.seedObservation(
            store,
            statement: "Use API B.",
            evidenceTexts: ["API B was selected."],
            startedAt: baseDate.addingTimeInterval(30))
        let confirmation = DecisionConfirmation(
            observationID: first.observationID,
            confirmedAt: baseDate.addingTimeInterval(60))
        let original = try await store.confirmDecision(confirmation)

        await XCTAssertThrowsDecisionContinuityError {
            _ = try await store.confirmDecision(DecisionConfirmation(
                decisionID: confirmation.decisionID,
                sourceID: confirmation.sourceID,
                eventID: confirmation.eventID,
                observationID: second.observationID,
                confirmedAt: confirmation.confirmedAt))
        }
        let retained = try await store.decisionContinuity(
            for: confirmation.decisionID)
        XCTAssertEqual(retained, original)
        let counts = try await DecisionContinuityTests.decisionCounts(store)
        XCTAssertEqual(counts, [1, 1, 1, 1])
    }

    func testLaterSourcesStayMonotonicAndOldRetriesRemainExact() async throws {
        let store = try MeetingStore.inMemory()
        let first = try await DecisionContinuityTests.seedObservation(
            store,
            statement: "Use API A.",
            evidenceTexts: ["API A was selected."],
            startedAt: baseDate)
        let second = try await DecisionContinuityTests.seedObservation(
            store,
            statement: "API A remains selected.",
            evidenceTexts: ["API A remains selected."],
            startedAt: baseDate.addingTimeInterval(10))
        let third = try await DecisionContinuityTests.seedObservation(
            store,
            statement: "API A is still selected.",
            evidenceTexts: ["API A is still selected."],
            startedAt: baseDate.addingTimeInterval(20))
        let confirmation = DecisionConfirmation(
            observationID: first.observationID,
            confirmedAt: baseDate)
        let initial = try await store.confirmDecision(confirmation)
        let secondRequest = DecisionSourceConfirmation(
            decisionID: confirmation.decisionID,
            observationID: second.observationID,
            confirmedAt: baseDate)
        let afterSecond = try await store.linkDecisionSource(secondRequest)
        let afterThird = try await store.linkDecisionSource(DecisionSourceConfirmation(
            decisionID: confirmation.decisionID,
            observationID: third.observationID,
            confirmedAt: baseDate))

        XCTAssertEqual(initial.sources.count, 1)
        XCTAssertGreaterThan(
            try XCTUnwrap(afterSecond.sources.last?.linkedAt),
            try XCTUnwrap(initial.sources.last?.linkedAt))
        XCTAssertGreaterThan(
            try XCTUnwrap(afterThird.sources.last?.linkedAt),
            try XCTUnwrap(afterSecond.sources.last?.linkedAt))
        let oldRetry = try await store.linkDecisionSource(secondRequest)
        XCTAssertEqual(oldRetry, afterThird)
    }

    func testSubmillisecondObservationCannotPostdateItsConfirmation() async throws {
        let store = try MeetingStore.inMemory()
        let observedAt = baseDate.addingTimeInterval(0.000_6)
        let seeded = try await DecisionContinuityTests.seedObservation(
            store,
            statement: "Use API A.",
            evidenceTexts: ["API A was selected."],
            startedAt: baseDate,
            summaryCreatedAt: observedAt)
        let confirmation = DecisionConfirmation(
            observationID: seeded.observationID,
            confirmedAt: baseDate.addingTimeInterval(0.000_2))

        let continuity = try await store.confirmDecision(confirmation)
        let retry = try await store.confirmDecision(confirmation)

        let source = try XCTUnwrap(continuity.sources.first)
        XCTAssertGreaterThanOrEqual(source.linkedAt, source.observedAt)
        XCTAssertEqual(source.linkedAt, continuity.events.first?.occurredAt)
        XCTAssertEqual(retry, continuity)
    }

    func testStaleAndNonfinalEvidenceRejectConfirmationAtomically() async throws {
        for mutation in ["stale", "nonfinal"] {
            let store = try MeetingStore.inMemory()
            let seeded = try await DecisionContinuityTests.seedObservation(
                store,
                statement: "Ship on Friday.",
                evidenceTexts: ["The rollout stays on Friday."],
                startedAt: baseDate)
            try await store.database.write { database in
                switch mutation {
                case "stale":
                    try database.execute(
                        sql: "UPDATE meeting SET transcriptRevision = 1 WHERE id = ?",
                        arguments: [seeded.meeting.id.rawValue.uuidString])
                default:
                    try database.execute(
                        sql: "UPDATE segment SET isFinal = 0 WHERE id = ?",
                        arguments: [seeded.segments[0].id.uuidString])
                }
            }

            await XCTAssertThrowsDecisionContinuityError {
                _ = try await store.confirmDecision(DecisionConfirmation(
                    observationID: seeded.observationID,
                    confirmedAt: self.baseDate.addingTimeInterval(1)))
            }
            let counts = try await DecisionContinuityTests.decisionCounts(store)
            XCTAssertEqual(counts, [0, 0, 0, 0])
        }
    }

    func testSourcePurgeKeepsImmutableMeetingAndSegmentIdentities() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await DecisionContinuityTests.seedObservation(
            store,
            statement: "Keep the compatibility layer.",
            evidenceTexts: ["The compatibility layer remains."],
            startedAt: baseDate)
        let confirmation = DecisionConfirmation(
            observationID: seeded.observationID,
            confirmedAt: baseDate.addingTimeInterval(1))
        _ = try await store.confirmDecision(confirmation)

        try await store.database.write { database in
            try database.execute(
                sql: "DELETE FROM meeting WHERE id = ?",
                arguments: [seeded.meeting.id.rawValue.uuidString])
        }
        let retained = try await store.decisionContinuity(for: confirmation.decisionID)

        XCTAssertEqual(retained.sources.map(\.meetingID), [seeded.meeting.id])
        XCTAssertEqual(
            retained.sources.flatMap { $0.evidence.map(\.segmentID) },
            seeded.segments.map(\.id))
        XCTAssertEqual(retained.sources.map(\.availability), [.unavailable])
    }

    func testInvalidRelationshipsAreAtomicAndTerminalDecisionCannotChangeAgain() async throws {
        let store = try MeetingStore.inMemory()
        let first = try await DecisionContinuityTests.seedObservation(
            store,
            statement: "Use API A.",
            evidenceTexts: ["API A was selected."],
            startedAt: baseDate)
        let second = try await DecisionContinuityTests.seedObservation(
            store,
            statement: "Use API B.",
            evidenceTexts: ["API B was selected."],
            startedAt: baseDate.addingTimeInterval(20))
        let third = try await DecisionContinuityTests.seedObservation(
            store,
            statement: "Use API C.",
            evidenceTexts: ["API C was selected."],
            startedAt: baseDate.addingTimeInterval(40))
        let firstConfirmation = DecisionConfirmation(
            observationID: first.observationID,
            confirmedAt: baseDate.addingTimeInterval(60))
        let secondConfirmation = DecisionConfirmation(
            observationID: second.observationID,
            confirmedAt: baseDate.addingTimeInterval(80))
        let thirdConfirmation = DecisionConfirmation(
            observationID: third.observationID,
            confirmedAt: baseDate.addingTimeInterval(100))
        _ = try await store.confirmDecision(firstConfirmation)
        _ = try await store.confirmDecision(secondConfirmation)
        _ = try await store.confirmDecision(thirdConfirmation)

        await XCTAssertThrowsDecisionContinuityError {
            _ = try await store.confirmDecisionRelationship(
                DecisionRelationshipConfirmation(
                    targetDecisionID: firstConfirmation.decisionID,
                    successorDecisionID: firstConfirmation.decisionID,
                    kind: .supersede,
                    confirmedAt: self.baseDate.addingTimeInterval(120)))
        }
        let terminalRequest = DecisionRelationshipConfirmation(
            targetDecisionID: firstConfirmation.decisionID,
            successorDecisionID: secondConfirmation.decisionID,
            kind: .supersede,
            confirmedAt: baseDate.addingTimeInterval(140))
        let terminal = try await store.confirmDecisionRelationship(terminalRequest)

        await XCTAssertThrowsDecisionContinuityError {
            _ = try await store.confirmDecisionRelationship(
                DecisionRelationshipConfirmation(
                    targetDecisionID: firstConfirmation.decisionID,
                    successorDecisionID: thirdConfirmation.decisionID,
                    kind: .reverse,
                    confirmedAt: self.baseDate.addingTimeInterval(160)))
        }
        let retained = try await store.decisionContinuity(
            for: firstConfirmation.decisionID)
        XCTAssertEqual(retained, terminal)
        let counts = try await DecisionContinuityTests.decisionCounts(store)
        XCTAssertEqual(counts, [3, 3, 3, 4])
    }

    func testRelationshipRetryIsExactAndEventIdentityReuseFailsClosed() async throws {
        let store = try MeetingStore.inMemory()
        let first = try await DecisionContinuityTests.seedObservation(
            store,
            statement: "Use API A.",
            evidenceTexts: ["API A was selected."],
            startedAt: baseDate)
        let second = try await DecisionContinuityTests.seedObservation(
            store,
            statement: "Use API B.",
            evidenceTexts: ["API B was selected."],
            startedAt: baseDate.addingTimeInterval(20))
        let firstConfirmation = DecisionConfirmation(
            observationID: first.observationID,
            confirmedAt: baseDate.addingTimeInterval(40))
        let secondConfirmation = DecisionConfirmation(
            observationID: second.observationID,
            confirmedAt: baseDate.addingTimeInterval(60))
        _ = try await store.confirmDecision(firstConfirmation)
        _ = try await store.confirmDecision(secondConfirmation)
        let request = DecisionRelationshipConfirmation(
            targetDecisionID: firstConfirmation.decisionID,
            successorDecisionID: secondConfirmation.decisionID,
            kind: .reverse,
            confirmedAt: baseDate.addingTimeInterval(80))

        let firstResult = try await store.confirmDecisionRelationship(request)
        let retry = try await store.confirmDecisionRelationship(request)
        XCTAssertEqual(retry, firstResult)

        await XCTAssertThrowsDecisionContinuityError {
            _ = try await store.confirmDecisionRelationship(
                DecisionRelationshipConfirmation(
                    targetDecisionID: firstConfirmation.decisionID,
                    successorDecisionID: secondConfirmation.decisionID,
                    kind: .supersede,
                    eventID: request.eventID,
                    confirmedAt: request.confirmedAt))
        }
        let counts = try await DecisionContinuityTests.decisionCounts(store)
        XCTAssertEqual(counts, [2, 2, 2, 3])
    }

    func testSchemaRejectsHistoryRewriteAndForeignConfirmationSource() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await DecisionContinuityTests.seedObservation(
            store,
            statement: "Keep API A.",
            evidenceTexts: ["API A remains."],
            startedAt: baseDate)
        let confirmation = DecisionConfirmation(
            observationID: seeded.observationID,
            confirmedAt: baseDate.addingTimeInterval(20))
        let continuity = try await store.confirmDecision(confirmation)
        let rewriteDate = baseDate
        let foreignEventDate = baseDate.addingTimeInterval(30)

        await XCTAssertThrowsDecisionContinuityError {
            try await store.database.write { database in
                try database.execute(
                    sql: "UPDATE decisionContinuitySource SET linkedAt = ? WHERE id = ?",
                    arguments: [rewriteDate, confirmation.sourceID.rawValue.uuidString])
            }
        }
        await XCTAssertThrowsDecisionContinuityError {
            try await store.database.write { database in
                try database.execute(
                    sql: "UPDATE decisionContinuity SET status = 'reversed' WHERE id = ?",
                    arguments: [confirmation.decisionID.rawValue.uuidString])
            }
        }
        await XCTAssertThrowsDecisionContinuityError {
            try await store.database.write { database in
                try database.execute(
                    sql: "UPDATE decisionContinuity SET id = ? WHERE id = ?",
                    arguments: [
                        DecisionID().rawValue.uuidString,
                        confirmation.decisionID.rawValue.uuidString
                    ])
            }
        }
        await XCTAssertThrowsDecisionContinuityError {
            try await store.database.write { database in
                try database.execute(
                    sql: "UPDATE decisionContinuityEvent SET kind = 'reverse' WHERE id = ?",
                    arguments: [confirmation.eventID.rawValue.uuidString])
            }
        }
        await XCTAssertThrowsDecisionContinuityError {
            try await store.database.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO decisionContinuityEvent (
                            id, decisionID, kind, sourceID, relatedDecisionID, occurredAt
                        ) VALUES (?, ?, 'confirm', ?, NULL, ?)
                        """,
                    arguments: [
                        UUID().uuidString,
                        confirmation.decisionID.rawValue.uuidString,
                        DecisionSourceID().rawValue.uuidString,
                        foreignEventDate
                    ])
            }
        }
        let retained = try await store.decisionContinuity(
            for: confirmation.decisionID)
        XCTAssertEqual(retained, continuity)
    }
}

func XCTAssertThrowsDecisionContinuityError(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
