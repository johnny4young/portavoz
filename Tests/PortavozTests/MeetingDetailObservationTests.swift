import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class MeetingDetailObservationTests: XCTestCase {
    func testV49IndexesTheCanonicalLiveTranscriptOrder() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v48")

        try migrator.migrate(database)

        try database.read { database in
            XCTAssertEqual(StorageSchema.version, 49)
            XCTAssertEqual(
                try String.fetchAll(
                    database,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
                ).last,
                "v49")
            let indexSQL = try XCTUnwrap(String.fetchOne(
                database,
                sql: """
                    SELECT sql FROM sqlite_master
                    WHERE type = 'index' AND name = 'segment_on_live_meeting_order'
                    """))
            XCTAssertTrue(
                indexSQL.contains("ON segment(meetingID, startTime, id)"),
                indexSQL)
            XCTAssertTrue(indexSQL.contains("WHERE deletedAt IS NULL"), indexSQL)

            let plan = try Row.fetchAll(
                database,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT * FROM segment
                    WHERE meetingID = ? AND deletedAt IS NULL
                    ORDER BY startTime, id
                    """,
                arguments: [UUID().uuidString]
            ).map { $0["detail"] as String }
            XCTAssertTrue(
                plan.contains(where: {
                    $0.contains("USING INDEX segment_on_live_meeting_order")
                }),
                "Meeting Detail must use the live-order index: \(plan)")
            XCTAssertFalse(
                plan.contains(where: { $0.contains("TEMP B-TREE") }),
                "Meeting Detail must not sort the complete transcript: \(plan)")
        }
    }

    func testObservedStreamReleasesGRDBIteratorWithItsConsumer() async throws {
        let store = try MeetingStore.inMemory()
        let cancelled = expectation(description: "GRDB observation cancelled")
        var token: ObservationLifetimeToken? = ObservationLifetimeToken()
        weak let releasedToken = token

        try await consumeOneObservation(
            from: store,
            retaining: try XCTUnwrap(token),
            onCancellation: { cancelled.fulfill() })
        token = nil

        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertNil(
            releasedToken,
            "Dropping the consumer must release GRDB's observation iterator")
    }

    func testProcessingObservationPublishesDurableRecoveryState() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Recovery", startedAt: Date())
        var processing = store.observeMeetingReviewProcessingJobs(
            meeting.id).makeAsyncIterator()
        let initial = try await nextProcessing(&processing)
        XCTAssertTrue(initial.isEmpty)

        try await store.save(meeting)
        _ = try await nextProcessing(&processing)
        _ = try await store.enqueueProcessingJobs(
            for: meeting.id,
            requests: [ProcessingJobRequest(
                kind: .transcription,
                inputFingerprint: "observation-recovery",
                maxAttempts: 1)])
        let pending = try await nextProcessing(&processing) {
            $0.first?.state == .pending
        }
        XCTAssertEqual(pending.first?.kind, .transcription)

        let claimedValue = try await store.claimNextProcessingJob(
            kinds: [.transcription],
            owner: "observation-worker",
            leaseDuration: 30)
        let claimed = try XCTUnwrap(claimedValue)
        _ = try await nextProcessing(&processing) { $0.first?.state == .running }
        _ = try await store.failProcessingJob(
            claimed.id,
            owner: "observation-worker",
            failure: ProcessingJobFailure(code: "processing.transcription.failed"))
        let failed = try await nextProcessing(&processing) {
            $0.first?.state == .failed
        }
        XCTAssertEqual(failed.first?.errorCode, "processing.transcription.failed")
    }

    func testMeetingReviewObservationsTrackLifecycleAndIndependentContent() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Planning", startedAt: Date())
        var core = store.observeMeetingReviewCore(meeting.id).makeAsyncIterator()
        var summary = store.observeMeetingReviewSummary(meeting.id).makeAsyncIterator()
        var companion = store.observeMeetingReviewCompanionCards(meeting.id).makeAsyncIterator()
        var privacy = store.observeMeetingReviewPrivacyReceipt(meeting.id).makeAsyncIterator()

        let initialCore = try await nextCore(&core)
        let initialSummary = try await nextSummary(&summary)
        let initialCompanion = try await nextCompanion(&companion)
        let initialPrivacy = try await nextPrivacy(&privacy)
        XCTAssertNil(initialCore)
        XCTAssertNil(initialSummary)
        XCTAssertTrue(initialCompanion.isEmpty)
        XCTAssertNil(initialPrivacy)

        try await store.save(meeting)
        let insertedCore = try await nextCore(&core) { $0?.meeting.id == meeting.id }
        _ = try await nextSummary(&summary)
        _ = try await nextCompanion(&companion)
        let insertedPrivacy = try await nextPrivacy(&privacy) { $0 != nil }
        XCTAssertEqual(insertedCore?.meeting.title, "Planning")
        XCTAssertEqual(insertedPrivacy?.status, .allContentStayedOnDevice)

        try await store.recordDataEgressEvent(DataEgressEvent(
            meetingID: meeting.id,
            operation: .summaryGeneration,
            destinationScope: .remote,
            destinationHost: "api.example.com",
            dataClassification: .meetingSummaryMaterial,
            consentSource: .summaryEngineSettings,
            providerID: "api.example.com",
            modelID: "summary-model",
            attemptedAt: Date()))
        let remotePrivacy = try await nextPrivacy(&privacy) {
            $0?.status == .remoteTransferAttempted
        }
        XCTAssertEqual(remotePrivacy?.remoteEvents.count, 1)

        let speaker = Speaker(meetingID: meeting.id, label: "S1", displayName: "Ana")
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: speaker.id,
            channel: .system,
            text: "Publicamos el viernes.",
            startTime: 0,
            endTime: 3,
            isFinal: true)
        try await store.save([speaker])
        _ = try await nextCore(&core)
        try await store.save([segment])
        let transcript = try await nextCore(&core) { $0?.segments.count == 1 }
        XCTAssertEqual(transcript?.speakers.first?.displayName, "Ana")
        XCTAssertEqual(transcript?.segments.first?.text, "Publicamos el viernes.")
        XCTAssertFalse(transcript?.isRefinedTranscript ?? true)

        let correction = TranscriptCorrectionEvent(
            meetingID: meeting.id,
            baseTranscriptRevision: meeting.transcriptRevision,
            targetSegmentIDs: [segment.id],
            kind: .replaceText(text: "Publicamos este viernes.", language: "es"),
            sourceDeviceID: UUID(),
            createdAt: Date())
        _ = try await store.appendTranscriptCorrection(correction)
        let correctedCore = try await nextCore(&core) {
            $0?.corrections.map(\.id) == [correction.id]
        }
        XCTAssertEqual(correctedCore?.corrections.map(\.id), [correction.id])
        XCTAssertEqual(correctedCore?.corrections.map(\.kind), [correction.kind])

        let action = ActionItem(text: "Publicar")
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "es",
            markdown: "## Resumen",
            actionItems: [action],
            claims: [SummaryClaim(
                kind: .overview,
                evidenceSegmentIDs: [segment.id])]))
        let firstSummary = try await nextSummary(&summary) { $0?.draft.actionItems.count == 1 }
        XCTAssertEqual(firstSummary?.version, 1)
        try await store.setActionItem(action.id, done: true)
        let completed = try await nextSummary(&summary) {
            $0?.draft.actionItems.first?.isDone == true
        }
        XCTAssertTrue(completed?.draft.actionItems.first?.isDone == true)
        let claim = try XCTUnwrap(firstSummary?.draft.claims.first)
        try await store.setSummaryClaimFeedback(
            .unsupported,
            for: claim.id,
            meetingID: meeting.id)
        let reviewed = try await nextSummary(&summary) {
            $0?.draft.claims.first?.feedback?.kind == .unsupported
        }
        XCTAssertEqual(reviewed?.draft.markdown, "## Resumen")

        let cardID = UUID()
        let card = CompanionCard(
            id: cardID,
            question: "¿Cuándo?",
            answer: "El viernes.",
            kind: .context,
            source: "meeting",
            askedAt: 1,
            evidence: CompanionCardEvidence(
                cardID: cardID,
                questionSegmentIDs: [segment.id],
                answerSegmentIDs: [segment.id]))
        try await store.save([card], for: meeting.id)
        let cards = try await nextCompanion(&companion) { $0.map(\.id) == [card.id] }
        XCTAssertEqual(cards.first?.answer, "El viernes.")
        XCTAssertEqual(cards.first?.evidence?.answerSegmentIDs, [segment.id])
        try await store.database.write { database in
            try database.execute(
                sql: "UPDATE companionCardEvidenceSegment SET segmentID = NULL WHERE role = ?",
                arguments: ["answer"])
        }
        let unavailable = try await nextCompanion(&companion) {
            $0.first?.evidence?.unavailableAnswerCount == 1
        }
        XCTAssertTrue(unavailable.first?.evidence?.answerSegmentIDs.isEmpty == true)
        try await store.deleteCompanionCard(card.id)
        let removedCards = try await nextCompanion(&companion) { $0.isEmpty }
        XCTAssertTrue(removedCards.isEmpty)

        try await store.delete(meeting.id)
        let deletedCore = try await nextCore(&core) { $0 == nil }
        let deletedSummary = try await nextSummary(&summary) { $0 == nil }
        let deletedCards = try await nextCompanion(&companion) { $0.isEmpty }
        let deletedPrivacy = try await nextPrivacy(&privacy) { $0 == nil }
        XCTAssertNil(deletedCore)
        XCTAssertNil(deletedSummary)
        XCTAssertTrue(deletedCards.isEmpty)
        XCTAssertNil(deletedPrivacy)

        try await store.restore(meeting.id)
        let restoredCore = try await nextCore(&core) { $0?.segments.count == 1 }
        let restoredSummary = try await nextSummary(&summary) {
            $0?.draft.actionItems.count == 1
        }
        let restoredCards = try await nextCompanion(&companion) { $0.isEmpty }
        let restoredPrivacy = try await nextPrivacy(&privacy) {
            $0?.status == .remoteTransferAttempted
        }
        XCTAssertEqual(
            restoredCore?.meeting.id,
            meeting.id)
        XCTAssertEqual(restoredSummary?.version, 1)
        XCTAssertTrue(restoredCards.isEmpty)
        XCTAssertEqual(restoredPrivacy?.remoteEvents.count, 1)
    }

    func testSummaryObservationSelectsNewestSnapshotAcrossRecipes() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Standup", startedAt: Date())
        try await store.save(meeting)
        var summary = store.observeMeetingReviewSummary(meeting.id).makeAsyncIterator()
        let initialSummary = try await nextSummary(&summary)
        XCTAssertNil(initialSummary)

        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "es",
            markdown: "General",
            actionItems: []))
        _ = try await nextSummary(&summary) { $0?.draft.markdown == "General" }
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.standup.id,
            language: "es",
            markdown: "Standup",
            actionItems: []))

        let newest = try await nextSummary(&summary) {
            $0?.draft.recipeID == Recipe.standup.id
        }
        XCTAssertEqual(newest?.draft.markdown, "Standup")
        XCTAssertEqual(newest?.version, 1)
    }
}

private func consumeOneObservation(
    from store: MeetingStore,
    retaining token: ObservationLifetimeToken,
    onCancellation: @escaping @Sendable () -> Void
) async throws {
    let observation = ValueObservation
        .tracking { _ in token.marker }
        .handleEvents(didCancel: onCancellation)
    var iterator = store.observedStream(observation).makeAsyncIterator()
    let observed = try await iterator.next()
    XCTAssertEqual(observed, token.marker)
}

private final class ObservationLifetimeToken: @unchecked Sendable {
    let marker = 7
}

private func nextCore(
    _ iterator: inout AsyncThrowingStream<MeetingStore.MeetingReviewCore?, Error>.Iterator,
    until predicate: (MeetingStore.MeetingReviewCore?) -> Bool = { _ in true }
) async throws -> MeetingStore.MeetingReviewCore? {
    for _ in 0..<12 {
        let value = try await iterator.next()
        if predicate(value ?? nil) { return value ?? nil }
    }
    throw MeetingDetailObservationTestError.expectedValue
}

private func nextProcessing(
    _ iterator: inout AsyncThrowingStream<[ProcessingJob], Error>.Iterator,
    until predicate: ([ProcessingJob]) -> Bool = { _ in true }
) async throws -> [ProcessingJob] {
    for _ in 0..<12 {
        let candidate = try await iterator.next()
        let value = try XCTUnwrap(candidate)
        if predicate(value) { return value }
    }
    throw MeetingDetailObservationTestError.expectedValue
}

private func nextSummary(
    _ iterator: inout AsyncThrowingStream<
        MeetingStore.MeetingReviewSummarySnapshot?,
        Error
    >.Iterator,
    until predicate: (MeetingStore.MeetingReviewSummarySnapshot?) -> Bool = { _ in true }
) async throws -> MeetingStore.MeetingReviewSummarySnapshot? {
    for _ in 0..<12 {
        let value = try await iterator.next()
        if predicate(value ?? nil) { return value ?? nil }
    }
    throw MeetingDetailObservationTestError.expectedValue
}

private func nextCompanion(
    _ iterator: inout AsyncThrowingStream<
        MeetingStore.MeetingReviewCompanionSnapshot,
        Error
    >.Iterator,
    until predicate: ([CompanionCard]) -> Bool = { _ in true }
) async throws -> [CompanionCard] {
    for _ in 0..<12 {
        let candidate = try await iterator.next()
        let value = try XCTUnwrap(candidate).cards
        if predicate(value) { return value }
    }
    throw MeetingDetailObservationTestError.expectedValue
}

private func nextPrivacy(
    _ iterator: inout AsyncThrowingStream<PrivacyReceipt?, Error>.Iterator,
    until predicate: (PrivacyReceipt?) -> Bool = { _ in true }
) async throws -> PrivacyReceipt? {
    for _ in 0..<12 {
        let value = try await iterator.next()
        if predicate(value ?? nil) { return value ?? nil }
    }
    throw MeetingDetailObservationTestError.expectedValue
}

private enum MeetingDetailObservationTestError: Error {
    case expectedValue
}
