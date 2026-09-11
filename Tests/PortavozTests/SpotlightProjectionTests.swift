import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class SpotlightProjectionTests: XCTestCase {
    private let sourceDeviceID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 64, 0, 144, 0, 0, 0, 0, 0, 0, 36))

    func testProjectionUsesNewestRecipeAndFirstFortyLiveSegmentsInOrder() async throws {
        let store = try MeetingStore.inMemory()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let meeting = Meeting(title: "Architecture review", startedAt: startedAt)
        try await store.save(meeting)

        let segments = (0..<42).reversed().map { index in
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "turn-\(index)",
                startTime: Double(index),
                endTime: Double(index) + 0.5,
                isFinal: true)
        }
        try await store.save(segments)
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "General summary",
            actionItems: []))
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.standup.id,
            language: "en",
            markdown: "Newest standup summary",
            actionItems: []))

        let documents = try await store.spotlightDocuments()
        let document = try XCTUnwrap(documents.first)

        XCTAssertEqual(document.meetingID, meeting.id)
        XCTAssertEqual(document.title, meeting.title)
        XCTAssertEqual(document.startedAt, startedAt)
        XCTAssertTrue(document.contentDescription.hasPrefix("Newest standup summary\n"))
        XCTAssertTrue(document.contentDescription.contains("turn-0 turn-1 turn-2"))
        XCTAssertTrue(document.contentDescription.hasSuffix("turn-39"))
        XCTAssertFalse(document.contentDescription.contains("turn-40"))
        XCTAssertFalse(document.contentDescription.contains("turn-41"))
    }

    func testProjectionExcludesTombstonesAndCapsDescription() async throws {
        let store = try MeetingStore.inMemory()
        let live = Meeting(title: "Live", startedAt: Date(timeIntervalSince1970: 200))
        let deleted = Meeting(title: "Deleted", startedAt: Date(timeIntervalSince1970: 100))
        try await store.save(live)
        try await store.save(deleted)
        try await store.delete(deleted.id)

        let retained = TranscriptSegment(
            meetingID: live.id,
            channel: .system,
            text: "retained",
            startTime: 1,
            endTime: 2,
            isFinal: true)
        let tombstoned = TranscriptSegment(
            meetingID: live.id,
            channel: .system,
            text: "must-not-index",
            startTime: 0,
            endTime: 1,
            isFinal: true)
        try await store.save([retained, tombstoned])
        try await store.database.write { db in
            try db.execute(
                sql: "UPDATE segment SET deletedAt = ? WHERE id = ?",
                arguments: [Date(), tombstoned.id.uuidString])
        }
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: live.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: String(repeating: "a", count: 4_100),
            actionItems: []))

        let documents = try await store.spotlightDocuments()

        XCTAssertEqual(documents.map(\.meetingID), [live.id])
        XCTAssertEqual(documents[0].contentDescription.count, 4_000)
        XCTAssertFalse(documents[0].contentDescription.contains("must-not-index"))
    }

    func testProjectionIsEmptyWithoutLiveMeetings() async throws {
        let store = try MeetingStore.inMemory()

        let documents = try await store.spotlightDocuments()
        XCTAssertTrue(documents.isEmpty)
    }

    func testProjectionUsesCorrectedTextAndOnlyCurrentSummaryLineage() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Correction review",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "the atlas rollout starts Monday",
            startTime: 0,
            endTime: 1,
            isFinal: true)
        try await store.save(meeting)
        try await store.save([segment])
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "Legacy rollout summary",
            actionItems: []))

        _ = try await store.appendTranscriptCorrection(correction(
            meeting: meeting,
            targets: [segment.id],
            kind: .replaceText(
                text: "the atlas deployment starts Monday",
                language: "en"),
            at: Date(timeIntervalSince1970: 1_700_000_100)))

        var documents = try await store.spotlightDocuments()
        var document = try XCTUnwrap(documents.first)
        XCTAssertTrue(document.contentDescription.contains("deployment"))
        XCTAssertFalse(document.contentDescription.contains("rollout"))
        let correctedStateCount = try await correctionStateCount(store)
        XCTAssertEqual(correctedStateCount, 1)

        let revision = try TranscriptCorrectionRevision.current(
            meetingID: meeting.id,
            baseTranscriptRevision: meeting.transcriptRevision,
            history: try await store.transcriptCorrectionHistory(for: meeting.id))
        let finishedAt = Date().addingTimeInterval(2)
        _ = try await store.saveSummary(
            SummaryDraft(
                meetingID: meeting.id,
                recipeID: Recipe.standup.id,
                language: "en",
                markdown: "Current deployment summary",
                actionItems: []),
            generationRun: GenerationRun(
                meetingID: meeting.id,
                kind: .summary,
                providerID: "spotlight-test",
                modelID: "deterministic",
                inputFingerprint: "current-correction",
                configJSON: """
                    {"sourceCorrectionRevision":"\(revision.rawValue)","sourceTranscriptRevision":0}
                    """,
                outputLanguage: "en",
                startedAt: finishedAt.addingTimeInterval(-1),
                finishedAt: finishedAt,
                outcome: .succeeded))

        documents = try await store.spotlightDocuments()
        document = try XCTUnwrap(documents.first)
        XCTAssertTrue(document.contentDescription.hasPrefix(
            "Current deployment summary\n"))
        XCTAssertTrue(document.contentDescription.contains("deployment"))
        XCTAssertFalse(document.contentDescription.contains("Legacy rollout summary"))
    }

    func testStructuralCorrectionOmitsTargetsAndRestoreReactivatesAcceptedMaterial() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Structural review",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let segments = (0..<41).map { index in
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "turn-\(index)",
                startTime: Double(index),
                endTime: Double(index) + 0.5,
                isFinal: true)
        }
        try await store.save(meeting)
        try await store.save(segments)
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "Accepted structural summary",
            actionItems: []))
        let suppression = correction(
            meeting: meeting,
            targets: [segments[0].id],
            kind: .suppress,
            at: Date(timeIntervalSince1970: 1_700_000_100))
        _ = try await store.appendTranscriptCorrection(suppression)

        var documents = try await store.spotlightDocuments()
        var document = try XCTUnwrap(documents.first)
        XCTAssertFalse(document.contentDescription.contains("turn-0 "))
        XCTAssertTrue(document.contentDescription.contains("turn-40"))
        XCTAssertFalse(document.contentDescription.contains("Accepted structural summary"))

        _ = try await store.appendTranscriptCorrection(correction(
            meeting: meeting,
            targets: suppression.targetSegmentIDs,
            kind: .restore,
            at: Date(timeIntervalSince1970: 1_700_000_200),
            supersedes: suppression.id))

        documents = try await store.spotlightDocuments()
        document = try XCTUnwrap(documents.first)
        XCTAssertTrue(document.contentDescription.hasPrefix(
            "Accepted structural summary\n"))
        XCTAssertTrue(document.contentDescription.contains("turn-0 turn-1"))
        XCTAssertFalse(document.contentDescription.contains("turn-40"))
        let restoredStateCount = try await correctionStateCount(store)
        XCTAssertEqual(restoredStateCount, 0)
    }

    func testProjectionIncludesSplitAndMergeRowsInsteadOfAcceptedTargets() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Structural search",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let speaker = Speaker(meetingID: meeting.id, label: "S1")
        let segments = [
            TranscriptSegment(
                meetingID: meeting.id,
                speakerID: speaker.id,
                channel: .system,
                text: "alpha accepted",
                language: "en",
                startTime: 0,
                endTime: 2,
                isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id,
                speakerID: speaker.id,
                channel: .system,
                text: "beta accepted",
                language: "en",
                startTime: 2,
                endTime: 4,
                isFinal: true)
        ]
        try await store.save(meeting)
        try await store.save([speaker])
        try await store.save(segments)
        let merge = correction(
            meeting: meeting,
            targets: segments.map(\.id),
            kind: .merge(
                replacementText: "merged structural wording",
                language: "en"),
            at: Date(timeIntervalSince1970: 1_700_000_100))
        _ = try await store.appendTranscriptCorrection(merge)

        var documents = try await store.spotlightDocuments()
        var document = try XCTUnwrap(documents.first)
        XCTAssertTrue(document.contentDescription.contains("merged structural wording"))
        XCTAssertFalse(document.contentDescription.contains("alpha accepted"))
        XCTAssertFalse(document.contentDescription.contains("beta accepted"))

        _ = try await store.appendTranscriptCorrection(correction(
            meeting: meeting,
            targets: merge.targetSegmentIDs,
            kind: .restore,
            at: Date(timeIntervalSince1970: 1_700_000_101),
            supersedes: merge.id))
        let split = correction(
            meeting: meeting,
            targets: [segments[0].id],
            kind: .split([
                TranscriptCorrectionPart(
                    text: "split alpha first",
                    speakerID: speaker.id,
                    language: "en",
                    startTime: 0,
                    endTime: 1),
                TranscriptCorrectionPart(
                    text: "split alpha second",
                    speakerID: speaker.id,
                    language: "en",
                    startTime: 1,
                    endTime: 2)
            ]),
            at: Date(timeIntervalSince1970: 1_700_000_102))
        _ = try await store.appendTranscriptCorrection(split)

        documents = try await store.spotlightDocuments()
        document = try XCTUnwrap(documents.first)
        XCTAssertTrue(document.contentDescription.contains(
            "split alpha first split alpha second beta accepted"))
        XCTAssertFalse(document.contentDescription.contains("alpha accepted"))
        XCTAssertFalse(document.contentDescription.contains("merged structural wording"))
    }

    func testMissingCorrectionStateFailsClosedAndProjectionCanRebuild() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Fence", startedAt: Date())
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "original material",
            startTime: 0,
            endTime: 1,
            isFinal: true)
        try await store.save(meeting)
        try await store.save([segment])
        _ = try await store.appendTranscriptCorrection(correction(
            meeting: meeting,
            targets: [segment.id],
            kind: .replaceText(text: "corrected material", language: "en"),
            at: Date()))

        try await store.database.write { database in
            try database.execute(sql: "DELETE FROM transcriptCorrectionSearchState")
        }
        var documents = try await store.spotlightDocuments()
        var document = try XCTUnwrap(documents.first)
        XCTAssertFalse(document.contentDescription.contains("original material"))
        XCTAssertFalse(document.contentDescription.contains("corrected material"))

        try await store.database.write { database in
            try MeetingStore.refreshTranscriptCorrectionSearchProjection(
                meetingID: meeting.id,
                in: database)
        }
        documents = try await store.spotlightDocuments()
        document = try XCTUnwrap(documents.first)
        XCTAssertTrue(document.contentDescription.contains("corrected material"))
    }

    func testMalformedSummaryGenerationConfigIsExcludedWithoutBreakingProjection() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Malformed provenance", startedAt: Date())
        try await store.save(meeting)
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "must not be indexed",
            actionItems: []))
        let run = GenerationRun(
            meetingID: meeting.id,
            kind: .summary,
            providerID: "spotlight-test",
            modelID: "forged",
            inputFingerprint: "malformed",
            configJSON: "{",
            outputLanguage: "en",
            startedAt: Date(),
            finishedAt: Date(),
            outcome: .succeeded)
        try await store.database.write { database in
            try GenerationRunRecord(run).insert(database)
            try database.execute(
                sql: "UPDATE summary SET generationRunID = ? WHERE meetingID = ?",
                arguments: [run.id.rawValue.uuidString, meeting.id.rawValue.uuidString])
        }

        let documents = try await store.spotlightDocuments()
        let document = try XCTUnwrap(documents.first)
        XCTAssertFalse(document.contentDescription.contains("must not be indexed"))
    }

    func testMigrationBackfillsCorrectionStateBeforeSpotlightReads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spotlight-correction-backfill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("library.sqlite")

        do {
            let store = try MeetingStore(databaseURL: databaseURL)
            let meeting = Meeting(title: "Upgrade", startedAt: Date())
            let segment = TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "original upgrade wording",
                startTime: 0,
                endTime: 1,
                isFinal: true)
            try await store.save(meeting)
            try await store.save([segment])
            _ = try await store.appendTranscriptCorrection(correction(
                meeting: meeting,
                targets: [segment.id],
                kind: .replaceText(text: "corrected upgrade wording", language: "en"),
                at: Date()))
            try await store.database.write { database in
                try database.execute(sql: "DROP TABLE transcriptCorrectionSearchState")
                try database.execute(
                    sql: "DELETE FROM grdb_migrations WHERE identifier = 'v36'")
            }
        }

        let reopened = try MeetingStore(databaseURL: databaseURL)
        let documents = try await reopened.spotlightDocuments()
        let document = try XCTUnwrap(documents.first)
        XCTAssertTrue(document.contentDescription.contains("corrected upgrade wording"))
        XCTAssertFalse(document.contentDescription.contains("original upgrade wording"))
        let stateCount = try await correctionStateCount(reopened)
        XCTAssertEqual(stateCount, 1)
    }

    func testUnifiedSnapshotIncludesOnlyLiveCanonicalEntities() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Entity source",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let speaker = Speaker(meetingID: meeting.id, label: "S1")
        try await store.save(meeting)
        try await store.save([speaker])
        let person = try await store.createPersonAndLink(
            speakerID: speaker.id,
            preferredName: "Ana",
            source: .manualName).person
        let visible = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Send the brief",
                origin: .manual(meetingID: meeting.id)),
            at: Date(timeIntervalSince1970: 1_700_000_100)).commitment
        let dismissed = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Discard this",
                origin: .manual(meetingID: meeting.id)),
            at: Date(timeIntervalSince1970: 1_700_000_200)).commitment
        _ = try await store.applyCommitmentTransition(
            .dismiss,
            to: dismissed.id,
            at: Date(timeIntervalSince1970: 1_700_000_300))

        let snapshot = try await store.spotlightIndexSnapshot()

        XCTAssertEqual(snapshot.meetings.map(\.meetingID), [meeting.id])
        XCTAssertEqual(snapshot.people, [SpotlightPersonDocument(
            personID: person.id,
            preferredName: person.preferredName)])
        XCTAssertEqual(snapshot.commitments.map(\.commitmentID), [visible.id])
        XCTAssertEqual(snapshot.commitments.map(\.title), [visible.title])
        XCTAssertFalse(snapshot.commitments.contains { $0.commitmentID == dismissed.id })
    }

    private func correction(
        meeting: Meeting,
        targets: [UUID],
        kind: TranscriptCorrectionKind,
        at timestamp: Date,
        supersedes: UUID? = nil
    ) -> TranscriptCorrectionEvent {
        TranscriptCorrectionEvent(
            meetingID: meeting.id,
            baseTranscriptRevision: meeting.transcriptRevision,
            targetSegmentIDs: targets,
            kind: kind,
            sourceDeviceID: sourceDeviceID,
            createdAt: timestamp,
            supersedesCorrectionID: supersedes)
    }

    private func correctionStateCount(_ store: MeetingStore) async throws -> Int {
        try await store.database.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM transcriptCorrectionSearchState") ?? 0
        }
    }
}
