import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

/// T28b/D313: a corrected word must be findable, the stale original must not
/// masquerade as current, and the citation identity of every hit stays the
/// accepted segment — the invariant that keeps RRF fusion, evidence linking,
/// and navigation working unchanged.
final class SegmentCorrectedTextSearchTests: XCTestCase {
    private let sourceDeviceID = UUID(
        uuidString: "00000000-0000-4000-9000-000000000002")!

    // MARK: - Search behavior against the real store

    func testReplaceTextCorrectionMovesTheLineToItsCorrectedText() async throws {
        let fixture = try await makeFixture(texts: [
            "the atlas rollout starts Monday",
            "an unrelated planning line"
        ])
        _ = try await fixture.store.appendTranscriptCorrection(event(
            201,
            fixture: fixture,
            targets: [fixture.segments[0].id],
            kind: .replaceText(text: "the atlas-500 deployment starts Monday", language: "en")))

        let correctedHits = try await fixture.store.search("deployment")
        XCTAssertEqual(correctedHits.count, 1)
        XCTAssertEqual(
            correctedHits.first?.segmentID, fixture.segments[0].id,
            "citation identity must stay the accepted segment")
        XCTAssertEqual(
            correctedHits.first?.text,
            "the atlas-500 deployment starts Monday")

        let staleHits = try await fixture.store.search("rollout")
        XCTAssertTrue(
            staleHits.isEmpty,
            "the replaced original text must stop serving as current")

        let untouched = try await fixture.store.search("unrelated")
        XCTAssertEqual(untouched.count, 1, "uncorrected lines are unaffected")
    }

    /// The bug this predicate split fixes: a speaker-only correction leaves
    /// the text untouched, so the line must stay findable. Discriminates the
    /// text-affecting predicate from the historical any-correction one.
    func testChangeSpeakerOnlyCorrectionKeepsTheLineSearchable() async throws {
        let fixture = try await makeFixture(texts: ["the quarterly budget review"])
        _ = try await fixture.store.appendTranscriptCorrection(event(
            202,
            fixture: fixture,
            targets: [fixture.segments[0].id],
            kind: .changeSpeaker(fixture.secondSpeaker.id)))

        let hits = try await fixture.store.search("quarterly")
        XCTAssertEqual(
            hits.count, 1,
            "a speaker correction does not change what text exists")
        XCTAssertEqual(hits.first?.segmentID, fixture.segments[0].id)
    }

    func testSuppressedSegmentStaysOutOfSearchEntirely() async throws {
        let fixture = try await makeFixture(texts: ["the confidential aside"])
        _ = try await fixture.store.appendTranscriptCorrection(event(
            203,
            fixture: fixture,
            targets: [fixture.segments[0].id],
            kind: .suppress))

        let hits = try await fixture.store.search("confidential")
        XCTAssertTrue(hits.isEmpty, "structural corrections keep today's exclusion")
        let projected = try await correctedRowCount(fixture)
        XCTAssertEqual(projected, 0)
    }

    func testRestoreReturnsTheLineToItsAcceptedText() async throws {
        let fixture = try await makeFixture(texts: ["the original wording stands"])
        let replace = event(
            204,
            fixture: fixture,
            targets: [fixture.segments[0].id],
            kind: .replaceText(text: "the corrected wording stands", language: "en"))
        _ = try await fixture.store.appendTranscriptCorrection(replace)
        _ = try await fixture.store.appendTranscriptCorrection(event(
            205,
            fixture: fixture,
            targets: [fixture.segments[0].id],
            kind: .restore,
            supersedes: replace.id))

        let original = try await fixture.store.search("original")
        XCTAssertEqual(original.count, 1, "restore reactivates the accepted text")
        let corrected = try await fixture.store.search("corrected")
        XCTAssertTrue(corrected.isEmpty, "the superseded replacement stops serving")
    }

    func testTombstonedCorrectionStopsServingItsText() async throws {
        let fixture = try await makeFixture(texts: ["the original wording stands"])
        let replace = event(
            206,
            fixture: fixture,
            targets: [fixture.segments[0].id],
            kind: .replaceText(text: "the corrected wording stands", language: "en"))
        _ = try await fixture.store.appendTranscriptCorrection(replace)
        _ = try await fixture.store.tombstoneTranscriptCorrection(
            replace.id,
            meetingID: fixture.meeting.id,
            at: date(300))

        let corrected = try await fixture.store.search("corrected")
        XCTAssertTrue(corrected.isEmpty)
        let original = try await fixture.store.search("original")
        XCTAssertEqual(original.count, 1)
    }

    /// The query-time revision guard is the belt behind the transactional
    /// refresh: even if a projection row survives a revision advance, it must
    /// not serve as current.
    func testCorrectedTextForAStaleRevisionNeverServes() async throws {
        let fixture = try await makeFixture(texts: ["the original wording stands"])
        _ = try await fixture.store.appendTranscriptCorrection(event(
            207,
            fixture: fixture,
            targets: [fixture.segments[0].id],
            kind: .replaceText(text: "the corrected wording stands", language: "en")))
        let served = try await fixture.store.search("corrected")
        XCTAssertEqual(served.count, 1)

        try await fixture.store.database.write { database in
            try database.execute(
                sql: "UPDATE meeting SET transcriptRevision = transcriptRevision + 1 WHERE id = ?",
                arguments: [fixture.meeting.id.rawValue.uuidString])
        }

        let corrected = try await fixture.store.search("corrected")
        XCTAssertTrue(
            corrected.isEmpty,
            "a revision advance makes every prior correction stale")
    }

    /// The projection is disposable: wipe it, refresh, and the corrected text
    /// serves again — including its FTS mirror.
    func testProjectionRebuildsFromCorrectionHistory() async throws {
        let fixture = try await makeFixture(texts: ["the original wording stands"])
        _ = try await fixture.store.appendTranscriptCorrection(event(
            208,
            fixture: fixture,
            targets: [fixture.segments[0].id],
            kind: .replaceText(text: "the corrected wording stands", language: "en")))

        let meetingID = fixture.meeting.id
        try await fixture.store.database.write { database in
            try database.execute(sql: "DELETE FROM segmentCorrectedText")
        }
        let wiped = try await fixture.store.search("corrected")
        XCTAssertTrue(wiped.isEmpty)

        try await fixture.store.database.write { database in
            try MeetingStore.refreshTranscriptCorrectionSearchProjection(
                meetingID: meetingID,
                in: database)
        }
        let served = try await fixture.store.search("corrected")
        XCTAssertEqual(served.count, 1)
    }

    /// An upgrade must not wait for the next correction write: v33 backfills
    /// the projection for libraries that corrected text before it existed.
    func testMigrationBackfillsCorrectedTextForExistingCorrections() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("segment-corrected-backfill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("library.sqlite")

        do {
            let fixture = try await makeFixture(
                texts: ["the original wording stands"],
                databaseURL: databaseURL)
            _ = try await fixture.store.appendTranscriptCorrection(event(
                209,
                fixture: fixture,
                targets: [fixture.segments[0].id],
                kind: .replaceText(
                    text: "the corrected wording stands", language: "en")))
            // Simulate a pre-v33 library: history exists and neither search
            // projection does. v33 must run before v36 creates sparse state.
            try await fixture.store.database.write { database in
                try database.execute(sql: "DROP TABLE transcriptCorrectionSearchState")
                try database.execute(sql: "DROP TABLE segmentCorrectedSearch")
                try database.execute(sql: "DROP TABLE segmentCorrectedText")
                try database.execute(
                    sql: "DELETE FROM grdb_migrations WHERE identifier IN ('v33', 'v36')")
            }
        }

        let reopened = try MeetingStore(databaseURL: databaseURL)
        let hits = try await reopened.search("corrected")
        XCTAssertEqual(hits.count, 1, "reopening runs v33 and its backfill")
    }

    // MARK: - Pure projection policy

    /// Two active replacements over one segment are an invalid history
    /// (`overlappingTargets`); the whole meeting projects nothing rather than
    /// guessing which text the user meant.
    func testTwoActiveReplacementsOverOneSegmentProjectNothing() {
        let meetingID = MeetingID()
        let segmentID = id(1)
        let events = [
            replacementEvent(11, meetingID: meetingID, target: segmentID, text: "first"),
            replacementEvent(12, meetingID: meetingID, target: segmentID, text: "second")
        ]
        XCTAssertTrue(
            SegmentCorrectedTextProjection.activeReplacements(
                history: events,
                meetingID: meetingID,
                baseTranscriptRevision: 3).isEmpty,
            "conflicting active replacements fail closed")
    }

    /// Active text + structural corrections on one segment are likewise an
    /// invalid history — the projection must not serve half of it.
    func testOverlappingTextAndStructuralHistoryProjectsNothing() {
        let meetingID = MeetingID()
        let corrected = id(1)
        let events = [
            replacementEvent(21, meetingID: meetingID, target: corrected, text: "changed"),
            TranscriptCorrectionEvent(
                id: id(23),
                meetingID: meetingID,
                baseTranscriptRevision: 3,
                targetSegmentIDs: [corrected],
                kind: .suppress,
                sourceDeviceID: sourceDeviceID,
                createdAt: date(23))
        ]
        XCTAssertTrue(
            SegmentCorrectedTextProjection.activeReplacements(
                history: events,
                meetingID: meetingID,
                baseTranscriptRevision: 3).isEmpty)
    }

    /// A structural correction elsewhere never bleeds into another segment's
    /// replacement: valid histories keep projecting the unaffected text.
    func testStructuralCorrectionOnAnotherSegmentKeepsTheReplacement() {
        let meetingID = MeetingID()
        let suppressed = id(1)
        let corrected = id(2)
        let events = [
            replacementEvent(31, meetingID: meetingID, target: corrected, text: "kept"),
            TranscriptCorrectionEvent(
                id: id(33),
                meetingID: meetingID,
                baseTranscriptRevision: 3,
                targetSegmentIDs: [suppressed],
                kind: .suppress,
                sourceDeviceID: sourceDeviceID,
                createdAt: date(33))
        ]
        let replacements = SegmentCorrectedTextProjection.activeReplacements(
            history: events,
            meetingID: meetingID,
            baseTranscriptRevision: 3)
        XCTAssertEqual(replacements.map(\.segmentID), [corrected])
        XCTAssertEqual(replacements.map(\.text), ["kept"])
    }

    func testMalformedHistoryProjectsNothing() {
        let meetingID = MeetingID()
        let duplicated = replacementEvent(
            31, meetingID: meetingID, target: id(1), text: "changed")
        XCTAssertTrue(
            SegmentCorrectedTextProjection.activeReplacements(
                history: [duplicated, duplicated],
                meetingID: meetingID,
                baseTranscriptRevision: 3).isEmpty)
    }

    func testStaleRevisionReplacementsProjectNothing() {
        let meetingID = MeetingID()
        let events = [
            replacementEvent(41, meetingID: meetingID, target: id(1), text: "changed")
        ]
        XCTAssertTrue(
            SegmentCorrectedTextProjection.activeReplacements(
                history: events,
                meetingID: meetingID,
                baseTranscriptRevision: 4).isEmpty,
            "events for another revision are not active")
    }

    // MARK: - Fixtures

    private struct Fixture {
        let store: MeetingStore
        let meeting: Meeting
        let firstSpeaker: Speaker
        let secondSpeaker: Speaker
        let segments: [TranscriptSegment]
    }

    private func makeFixture(
        texts: [String],
        databaseURL: URL? = nil
    ) async throws -> Fixture {
        let store: MeetingStore
        if let databaseURL {
            store = try MeetingStore(databaseURL: databaseURL)
        } else {
            store = try MeetingStore.inMemory()
        }
        let meeting = Meeting(
            title: "Corrected search",
            startedAt: date(0),
            language: "en",
            transcriptRevision: 3)
        let firstSpeaker = Speaker(meetingID: meeting.id, label: "S1")
        let secondSpeaker = Speaker(meetingID: meeting.id, label: "S2")
        let segments = texts.enumerated().map { index, text in
            TranscriptSegment(
                id: id(index + 1),
                meetingID: meeting.id,
                speakerID: firstSpeaker.id,
                channel: .system,
                text: text,
                language: "en",
                startTime: Double(index * 3),
                endTime: Double(index * 3 + 2),
                confidence: 0.9,
                isFinal: true)
        }
        try await store.save(meeting)
        try await store.save([firstSpeaker, secondSpeaker])
        try await store.save(segments)
        return Fixture(
            store: store,
            meeting: meeting,
            firstSpeaker: firstSpeaker,
            secondSpeaker: secondSpeaker,
            segments: segments)
    }

    private func correctedRowCount(_ fixture: Fixture) async throws -> Int {
        try await fixture.store.database.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM segmentCorrectedText") ?? 0
        }
    }

    private func event(
        _ value: Int,
        fixture: Fixture,
        targets: [UUID],
        kind: TranscriptCorrectionKind,
        supersedes: UUID? = nil
    ) -> TranscriptCorrectionEvent {
        TranscriptCorrectionEvent(
            id: id(value),
            meetingID: fixture.meeting.id,
            baseTranscriptRevision: fixture.meeting.transcriptRevision,
            targetSegmentIDs: targets,
            kind: kind,
            sourceDeviceID: sourceDeviceID,
            createdAt: date(Double(value)),
            supersedesCorrectionID: supersedes)
    }

    private func replacementEvent(
        _ value: Int,
        meetingID: MeetingID,
        target: UUID,
        text: String
    ) -> TranscriptCorrectionEvent {
        TranscriptCorrectionEvent(
            id: id(value),
            meetingID: meetingID,
            baseTranscriptRevision: 3,
            targetSegmentIDs: [target],
            kind: .replaceText(text: text, language: "en"),
            sourceDeviceID: sourceDeviceID,
            createdAt: date(Double(value)))
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_810_000_000 + offset)
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-9%011d", value))!
    }
}
