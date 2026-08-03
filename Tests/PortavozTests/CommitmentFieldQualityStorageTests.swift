import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class CommitmentFieldQualityStorageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSchemaV24AddsOnlyImmutableContentFreePresentationEvidence() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v23")
        try migrator.migrate(database)

        try database.write { database in
            XCTAssertEqual(StorageSchema.version, 30)
            XCTAssertEqual(
                try Set(database.columns(in: "commitmentFieldPresentation").map(\.name)),
                [
                    "id", "actionItemID", "language", "suggestedOwnerToken",
                    "suggestedDueAt", "firstPresentedAt",
                ])
            XCTAssertTrue(try database.foreignKeys(
                on: "commitmentFieldPresentation").isEmpty)
            XCTAssertEqual(
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM commitmentFieldPresentation"),
                0)

            let observationID = UUID().uuidString
            try database.execute(
                sql: """
                    INSERT INTO commitmentFieldPresentation (
                        id, actionItemID, language, suggestedOwnerToken,
                        suggestedDueAt, firstPresentedAt
                    ) VALUES (?, ?, 'english', NULL, NULL, ?)
                    """,
                arguments: [observationID, UUID().uuidString, now])
            XCTAssertThrowsError(try database.execute(
                sql: """
                    UPDATE commitmentFieldPresentation
                    SET language = 'spanish'
                    WHERE id = ?
                    """,
                arguments: [observationID]))
        }
    }

    func testFirstPresentationIsIdempotentAndCapturesOnlyInitialClaims() async throws {
        let store = try MeetingStore.inMemory()
        let fixture = try await makeCandidate(
            in: store,
            title: "Mixed rollout",
            languages: ["en-US", "es-CO"])
        let observationID = UUID()
        let presentedAt = now.addingTimeInterval(-60)

        let first = try await store.recordCommitmentFieldPresentation(
            actionItemID: fixture.actionItem.id,
            meetingID: fixture.meeting.id,
            observationID: observationID,
            at: presentedAt)
        let replay = try await store.recordCommitmentFieldPresentation(
            actionItemID: fixture.actionItem.id,
            meetingID: fixture.meeting.id,
            observationID: UUID(),
            at: now)

        XCTAssertEqual(first, observationID)
        XCTAssertEqual(replay, observationID)
        let observations = try await store.commitmentFieldQualityObservations(
            endingAt: now)
        let observation = try XCTUnwrap(observations.first)
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observation.id, observationID)
        XCTAssertEqual(observation.language, .mixed)
        XCTAssertEqual(observation.firstPresentedAt, presentedAt)
        XCTAssertEqual(observation.outcome, .pending)
        XCTAssertNotNil(observation.suggestedOwnerToken)
        XCTAssertNotEqual(
            observation.suggestedOwnerToken,
            fixture.personID.rawValue)
        XCTAssertNil(observation.suggestedDueAt)
        XCTAssertNoThrow(try CommitmentFieldQualityEvaluator.evaluate(
            observations,
            endingAt: now))
    }

    func testFirstPresentationRejectsSourcesOutsideTheCurrentReviewQueue() async throws {
        let store = try MeetingStore.inMemory()
        let confirmed = try await makeCandidate(
            in: store,
            title: "Already confirmed",
            languages: ["en"])
        let dismissed = try await makeCandidate(
            in: store,
            title: "Already dismissed",
            languages: ["es"])
        let deferred = try await makeCandidate(
            in: store,
            title: "Review later",
            languages: ["en"])
        _ = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: confirmed.actionItem.text,
                assignee: .person(confirmed.personID),
                origin: .generatedActionItem(confirmed.actionItem.id)),
            at: now.addingTimeInterval(-30))
        try await store.setCommitmentReviewDecision(
            .dismissed,
            for: dismissed.actionItem.id,
            meetingID: dismissed.meeting.id,
            at: now.addingTimeInterval(-30))
        try await store.setCommitmentReviewDecision(
            .deferred,
            for: deferred.actionItem.id,
            meetingID: deferred.meeting.id,
            revisitAt: now.addingTimeInterval(3_600),
            at: now.addingTimeInterval(-30))

        for fixture in [confirmed, dismissed, deferred] {
            do {
                _ = try await store.recordCommitmentFieldPresentation(
                    actionItemID: fixture.actionItem.id,
                    meetingID: fixture.meeting.id,
                    at: now)
                XCTFail("Expected non-reviewable source to be rejected")
            } catch let error as StorageError {
                guard case .invalidCommitment = error else {
                    return XCTFail("Unexpected storage error: \(error)")
                }
            }
        }
    }

    func testAssemblyUsesFirstConfirmationInsteadOfMutableProjection() async throws {
        let store = try MeetingStore.inMemory()
        let fixture = try await makeCandidate(
            in: store,
            title: "Publish rollout",
            languages: ["en"])
        let dueAt = now.addingTimeInterval(86_400)
        _ = try await store.recordCommitmentFieldPresentation(
            actionItemID: fixture.actionItem.id,
            meetingID: fixture.meeting.id,
            at: now.addingTimeInterval(-60))
        let envelope = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: fixture.actionItem.text,
                assignee: .person(fixture.personID),
                dueAt: dueAt,
                origin: .generatedActionItem(fixture.actionItem.id)),
            at: now.addingTimeInterval(-30))
        _ = try await store.applyCommitmentTransition(
            .reassign(.me),
            to: envelope.commitment.id,
            at: now.addingTimeInterval(-20))
        _ = try await store.applyCommitmentTransition(
            .reschedule(now.addingTimeInterval(172_800)),
            to: envelope.commitment.id,
            at: now.addingTimeInterval(-10))

        let observations = try await store.commitmentFieldQualityObservations(
            endingAt: now)
        let observation = try XCTUnwrap(observations.first)
        XCTAssertEqual(observation.outcome, .confirmed)
        XCTAssertEqual(observation.reviewedAt, now.addingTimeInterval(-30))
        XCTAssertEqual(
            observation.confirmedOwnerToken,
            observation.suggestedOwnerToken)
        XCTAssertEqual(observation.confirmedDueAt, dueAt)
        XCTAssertEqual(observation.confirmationBasis, .generatedDirectEvidence)
        XCTAssertNil(observation.suggestedDueAt)
    }

    func testAssemblyDistinguishesHumanReviewFromSourceWithdrawal() async throws {
        let store = try MeetingStore.inMemory()
        let dismissed = try await makeCandidate(
            in: store,
            title: "Dismissed",
            languages: ["es"])
        let deferred = try await makeCandidate(
            in: store,
            title: "Deferred",
            languages: ["en"])
        let withdrawn = try await makeCandidate(
            in: store,
            title: "Withdrawn",
            languages: [nil])
        for fixture in [dismissed, deferred, withdrawn] {
            _ = try await store.recordCommitmentFieldPresentation(
                actionItemID: fixture.actionItem.id,
                meetingID: fixture.meeting.id,
                at: now.addingTimeInterval(-60))
        }
        try await store.setCommitmentReviewDecision(
            .dismissed,
            for: dismissed.actionItem.id,
            meetingID: dismissed.meeting.id,
            at: now.addingTimeInterval(-30))
        try await store.setCommitmentReviewDecision(
            .deferred,
            for: deferred.actionItem.id,
            meetingID: deferred.meeting.id,
            revisitAt: now.addingTimeInterval(3_600),
            at: now.addingTimeInterval(-30))
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: withdrawn.meeting.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "No current commitment candidates.",
            actionItems: []))

        let observations = try await store.commitmentFieldQualityObservations(
            endingAt: now)
        let byID = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })
        let records = try await presentationIDs(
            in: store,
            actionItemIDs: [
                dismissed.actionItem.id,
                deferred.actionItem.id,
                withdrawn.actionItem.id,
            ])
        XCTAssertEqual(byID[try XCTUnwrap(records[dismissed.actionItem.id])]?.outcome,
                       .dismissed)
        XCTAssertEqual(byID[try XCTUnwrap(records[deferred.actionItem.id])]?.outcome,
                       .deferred)
        let withdrawnObservation = try XCTUnwrap(
            byID[try XCTUnwrap(records[withdrawn.actionItem.id])])
        XCTAssertEqual(withdrawnObservation.outcome, .withdrawn)
        XCTAssertEqual(withdrawnObservation.language, .otherOrUnknown)

        let replay = try await store.recordCommitmentFieldPresentation(
            actionItemID: withdrawn.actionItem.id,
            meetingID: withdrawn.meeting.id,
            at: now)
        XCTAssertEqual(replay, withdrawnObservation.id)
    }

    func testAssemblyUsesOneReadIndependentOfPresentationCount() async throws {
        let store = try MeetingStore.inMemory()
        for index in 0..<12 {
            let fixture = try await makeCandidate(
                in: store,
                title: "Candidate \(index)",
                languages: [index.isMultiple(of: 2) ? "en" : "es"])
            _ = try await store.recordCommitmentFieldPresentation(
                actionItemID: fixture.actionItem.id,
                meetingID: fixture.meeting.id,
                at: now.addingTimeInterval(Double(index - 20)))
        }
        let counter = CommitmentFieldQualityStatementCounter()
        try await store.database.write { database in
            database.trace(options: .statement) { counter.record($0) }
        }

        let observations = try await store.commitmentFieldQualityObservations(
            endingAt: now)

        try await store.database.write { database in
            database.trace(options: [])
        }
        XCTAssertEqual(observations.count, 12)
        XCTAssertEqual(counter.readStatementCount, 1)
    }
}

private extension CommitmentFieldQualityStorageTests {
    struct CandidateFixture {
        let meeting: Meeting
        let actionItem: ActionItem
        let personID: PersonID
    }

    func makeCandidate(
        in store: MeetingStore,
        title: String,
        languages: [String?]
    ) async throws -> CandidateFixture {
        let meeting = Meeting(
            title: title,
            startedAt: now.addingTimeInterval(-3_600),
            endedAt: now.addingTimeInterval(-1_800))
        let speaker = Speaker(meetingID: meeting.id, label: "S1", displayName: "Ana")
        let segments = languages.enumerated().map { index, language in
            TranscriptSegment(
                meetingID: meeting.id,
                speakerID: speaker.id,
                channel: .system,
                text: "Synthetic evidence \(index)",
                language: language,
                startTime: Double(index),
                endTime: Double(index + 1),
                isFinal: true)
        }
        try await store.save(meeting)
        try await store.save([speaker])
        try await store.save(segments)
        let person = try await store.createPersonAndLink(
            speakerID: speaker.id,
            preferredName: "Ana",
            source: .manualName)
        let actionItem = ActionItem(text: title, ownerSpeakerID: speaker.id)
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "Synthetic summary",
            actionItems: [actionItem],
            actionItemEvidence: [SummaryActionItemEvidence(
                actionItemID: actionItem.id,
                evidenceSegmentIDs: segments.map(\.id))]))
        return CandidateFixture(
            meeting: meeting,
            actionItem: actionItem,
            personID: person.person.id)
    }

    func presentationIDs(
        in store: MeetingStore,
        actionItemIDs: [UUID]
    ) async throws -> [UUID: UUID] {
        try await store.database.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, actionItemID
                    FROM commitmentFieldPresentation
                    WHERE actionItemID IN (\(databaseQuestionMarks(count: actionItemIDs.count)))
                    """,
                arguments: StatementArguments(actionItemIDs.map(\.uuidString)))
            return try Dictionary(uniqueKeysWithValues: rows.map { row in
                let actionItemID: String = row["actionItemID"]
                let observationID: String = row["id"]
                return (
                    try XCTUnwrap(UUID(uuidString: actionItemID)),
                    try XCTUnwrap(UUID(uuidString: observationID)))
            })
        }
    }
}

private final class CommitmentFieldQualityStatementCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var statements = 0

    var readStatementCount: Int {
        lock.withLock { statements }
    }

    func record(_ event: Database.TraceEvent) {
        guard case .statement(let statement) = event else { return }
        let sql = statement.sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard sql.hasPrefix("SELECT") || sql.hasPrefix("WITH") else { return }
        lock.withLock { statements += 1 }
    }
}
