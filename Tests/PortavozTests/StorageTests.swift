import Foundation
import PortavozCore
import XCTest

@testable import StorageKit

final class MeetingStoreTests: XCTestCase {
    private var store: MeetingStore!
    private var meeting: Meeting!

    override func setUpWithError() throws {
        store = try MeetingStore.inMemory()
        meeting = Meeting(
            title: "Planning semanal",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            language: "es",
            audioDirectory: "meetings/planning-semanal",
            retention: .deleteAfter(days: 7)
        )
    }

    private func seedMeetingWithTranscript() async throws -> (Speaker, [TranscriptSegment]) {
        try await store.save(meeting)
        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        let ana = Speaker(meetingID: meeting.id, label: "S1", displayName: "Ana")
        try await store.save([me, ana])
        let segments = [
            TranscriptSegment(
                meetingID: meeting.id, speakerID: me.id, channel: .microphone,
                text: "revisemos el presupuesto de transcripción",
                startTime: 0, endTime: 4, isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id, speakerID: ana.id, channel: .system,
                text: "el rollout del modelo queda para el viernes",
                startTime: 5, endTime: 9, isFinal: true),
        ]
        try await store.save(segments)
        return (ana, segments)
    }

    // MARK: - Roundtrips (UUID PKs, D4)

    func testMeetingRoundTripsWithTypedIDsAndRetention() async throws {
        _ = try await seedMeetingWithTranscript()

        let detail = try await store.detail(meeting.id)
        XCTAssertNotNil(detail)
        XCTAssertEqual(detail?.meeting.id, meeting.id)
        XCTAssertEqual(detail?.meeting.title, "Planning semanal")
        XCTAssertEqual(detail?.meeting.retention, .deleteAfter(days: 7))
        XCTAssertEqual(detail?.meeting.visibility, "private")
        XCTAssertEqual(detail?.speakers.count, 2)
        XCTAssertEqual(detail?.segments.count, 2)
        XCTAssertEqual(detail?.segments.first?.text, "revisemos el presupuesto de transcripción")
        XCTAssertEqual(detail?.segments.first?.channel, .microphone)
    }

    func testSaveIsUpsertKeepingIdentity() async throws {
        try await store.save(meeting)
        var renamed = meeting!
        renamed.title = "Planning semanal (editado)"
        try await store.save(renamed)

        let all = try await store.meetings()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.title, "Planning semanal (editado)")
    }

    // MARK: - D4: no absolute paths

    func testAbsoluteAudioPathsAreRejected() async throws {
        var bad = meeting!
        bad.audioDirectory = "/Users/johnny/Desktop/audio"
        do {
            try await store.save(bad)
            XCTFail("expected absolutePathRejected")
        } catch let error as StorageError {
            guard case .absolutePathRejected = error else {
                return XCTFail("wrong error: \(error)")
            }
        }

        bad.audioDirectory = "meetings/../../etc"
        do {
            try await store.save(bad)
            XCTFail("expected absolutePathRejected for traversal")
        } catch let error as StorageError {
            guard case .absolutePathRejected = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    // MARK: - D4: tombstones

    func testDeleteIsATombstone() async throws {
        _ = try await seedMeetingWithTranscript()
        try await store.delete(meeting.id)

        let visible = try await store.meetings()
        XCTAssertTrue(visible.isEmpty)
        let all = try await store.meetings(includeDeleted: true)
        XCTAssertEqual(all.count, 1, "the row must survive for sync")

        let detail = try await store.detail(meeting.id)
        XCTAssertNil(detail, "tombstoned meetings don't load")
    }

    // MARK: - D4: summaries are immutable versioned snapshots

    func testSummaryVersionsIncrementAndOldSnapshotsSurvive() async throws {
        _ = try await seedMeetingWithTranscript()

        let first = SummaryDraft(
            meetingID: meeting.id, recipeID: Recipe.general.id, language: "es",
            markdown: "# v1", actionItems: [ActionItem(text: "preparar rollout")])
        let second = SummaryDraft(
            meetingID: meeting.id, recipeID: Recipe.general.id, language: "es",
            markdown: "# v2", actionItems: [])

        let v1 = try await store.saveSummary(first)
        let v2 = try await store.saveSummary(second)
        XCTAssertEqual(v1, 1)
        XCTAssertEqual(v2, 2)

        let latest = try await store.summary(meeting.id)
        XCTAssertEqual(latest?.version, 2)
        XCTAssertEqual(latest?.draft.markdown, "# v2")

        let original = try await store.summary(meeting.id, version: 1)
        XCTAssertEqual(original?.draft.markdown, "# v1")
        XCTAssertEqual(original?.draft.actionItems.count, 1)
    }

    func testSummaryRequiresExistingMeeting() async throws {
        let orphan = SummaryDraft(
            meetingID: MeetingID(), recipeID: "general", language: "en",
            markdown: "x", actionItems: [])
        do {
            _ = try await store.saveSummary(orphan)
            XCTFail("expected meetingNotFound")
        } catch let error as StorageError {
            guard case .meetingNotFound = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testActionItemsToggle() async throws {
        _ = try await seedMeetingWithTranscript()
        let item = ActionItem(text: "preparar rollout")
        let draft = SummaryDraft(
            meetingID: meeting.id, recipeID: Recipe.general.id, language: "es",
            markdown: "# v1", actionItems: [item])
        try await store.saveSummary(draft)

        try await store.setActionItem(item.id, done: true)
        let loaded = try await store.summary(meeting.id)
        XCTAssertEqual(loaded?.draft.actionItems.first?.isDone, true)
    }

    // MARK: - FTS5

    func testFullTextSearchFindsSegmentsWithSnippets() async throws {
        _ = try await seedMeetingWithTranscript()

        let hits = try await store.search("presupuesto")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.meetingTitle, "Planning semanal")
        XCTAssertTrue(hits.first?.snippet.contains("[presupuesto]") ?? false)
        XCTAssertEqual(hits.first?.startTime, 0)

        // Multi-token queries AND together.
        let both = try await store.search("rollout viernes")
        XCTAssertEqual(both.count, 1)
        XCTAssertTrue(both.first?.snippet.contains("[rollout]") ?? false)

        let none = try await store.search("kubernetes")
        XCTAssertTrue(none.isEmpty)
    }

    func testSearchExcludesTombstonedMeetings() async throws {
        _ = try await seedMeetingWithTranscript()
        try await store.delete(meeting.id)
        let hits = try await store.search("presupuesto")
        XCTAssertTrue(hits.isEmpty)
    }

    func testHostileSearchInputIsHarmless() async throws {
        _ = try await seedMeetingWithTranscript()
        for hostile in ["\"", "AND OR NOT", "col:x", "(((", "'; DROP TABLE meeting;--"] {
            _ = try await store.search(hostile)  // must not throw
        }
        let survivors = try await store.meetings()
        XCTAssertEqual(survivors.count, 1)
    }

    // MARK: - Audio retention (M1 deferral closed here)

    func testRetentionDeletesExpiredAudioAndClearsReference() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-retention-\(UUID().uuidString)")
        let audioDir = root.appendingPathComponent("meetings/planning-semanal")
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try Data("RIFF".utf8).write(to: audioDir.appendingPathComponent("microphone.wav"))
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await seedMeetingWithTranscript()  // retention: 7 días

        // Day 6: nothing happens.
        let early = try await store.enforceAudioRetention(
            audioRoot: root, now: meeting.endedAt!.addingTimeInterval(6 * 86_400))
        XCTAssertTrue(early.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioDir.path))

        // Day 8: audio goes, transcript stays, reference cleared.
        let removed = try await store.enforceAudioRetention(
            audioRoot: root, now: meeting.endedAt!.addingTimeInterval(8 * 86_400))
        XCTAssertEqual(removed.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioDir.path))

        let detail = try await store.detail(meeting.id)
        XCTAssertNil(detail?.meeting.audioDirectory)
        XCTAssertEqual(detail?.segments.count, 2, "transcript must survive retention")
    }

    func testDeleteAfterTranscriptionWaitsForFinalSegments() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-retention-\(UUID().uuidString)")
        let audioDir = root.appendingPathComponent("meetings/sin-transcript")
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var eager = Meeting(
            title: "Sin transcript",
            startedAt: Date(),
            audioDirectory: "meetings/sin-transcript",
            retention: .deleteAfterTranscription
        )
        try await store.save(eager)

        // No transcript yet → audio stays.
        let before = try await store.enforceAudioRetention(audioRoot: root)
        XCTAssertTrue(before.isEmpty)

        try await store.save([
            TranscriptSegment(
                meetingID: eager.id, channel: .microphone, text: "listo",
                startTime: 0, endTime: 1, isFinal: true)
        ])
        let after = try await store.enforceAudioRetention(audioRoot: root)
        XCTAssertEqual(after.count, 1)
        _ = eager
    }
}
