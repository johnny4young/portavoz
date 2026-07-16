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
        meeting.lifecycleState = .needsAttention
        meeting.transcriptRevision = 2
        meeting.lastProcessingError = "summary.exhausted"
        _ = try await seedMeetingWithTranscript()

        let detail = try await store.detail(meeting.id)
        XCTAssertNotNil(detail)
        XCTAssertEqual(detail?.meeting.id, meeting.id)
        XCTAssertEqual(detail?.meeting.title, "Planning semanal")
        XCTAssertEqual(detail?.meeting.language, "es")
        XCTAssertEqual(detail?.meeting.retention, .deleteAfter(days: 7))
        XCTAssertEqual(detail?.meeting.visibility, "private")
        XCTAssertEqual(detail?.meeting.lifecycleState, .needsAttention)
        XCTAssertEqual(detail?.meeting.transcriptRevision, 2)
        XCTAssertEqual(detail?.meeting.lastProcessingError, "summary.exhausted")
        XCTAssertEqual(detail?.speakers.count, 2)
        XCTAssertEqual(detail?.segments.count, 2)
        XCTAssertEqual(detail?.segments.first?.text, "revisemos el presupuesto de transcripción")
        XCTAssertEqual(detail?.segments.first?.channel, .microphone)
    }

    func testInvalidPersistedUUIDFailsInsteadOfMintingIdentity() throws {
        var record = try MeetingRecord(
            meeting, createdAt: Date(), updatedAt: Date())
        record.id = "corrupt-meeting-id"

        XCTAssertThrowsError(try record.meeting) { error in
            guard case StorageError.invalidPersistedUUID(
                table: "meeting", column: "id", value: "corrupt-meeting-id") = error
            else { return XCTFail("wrong error: \(error)") }
        }

        XCTAssertThrowsError(
            try PersistedIdentity.optional(
                "corrupt-speaker-id", table: "segment", column: "speakerID")
        ) { error in
            guard case StorageError.invalidPersistedUUID(
                table: "segment", column: "speakerID", value: "corrupt-speaker-id") = error
            else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testCorruptDatabaseIdentityFailsThroughPublicRead() async throws {
        try await store.save(meeting)
        let meetingKey = meeting.id.rawValue.uuidString
        try await store.database.write { db in
            try db.execute(
                sql: "UPDATE meeting SET id = ? WHERE id = ?",
                arguments: ["corrupt-meeting-id", meetingKey])
        }

        do {
            _ = try await store.meetings()
            XCTFail("corrupt persisted identity should fail the public read")
        } catch {
            guard case StorageError.invalidPersistedUUID(
                table: "meeting", column: "id", value: "corrupt-meeting-id") = error
            else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testInvalidPersistedEnumFailsInsteadOfChangingMeaning() throws {
        let segment = TranscriptSegment(
            meetingID: meeting.id, channel: .microphone, text: "hola",
            startTime: 0, endTime: 1)
        var record = SegmentRecord(segment, createdAt: Date(), updatedAt: Date())
        record.channel = "corrupt-channel"

        XCTAssertThrowsError(try record.segment) { error in
            guard case StorageError.invalidPersistedValue(
                table: "segment", column: "channel", value: "corrupt-channel") = error
            else { return XCTFail("wrong error: \(error)") }
        }

        var meetingRecord = try MeetingRecord(
            meeting, createdAt: Date(), updatedAt: Date())
        meetingRecord.lifecycleState = "corrupt-lifecycle"
        XCTAssertThrowsError(try meetingRecord.meeting) { error in
            guard case StorageError.invalidPersistedValue(
                table: "meeting", column: "lifecycleState", value: "corrupt-lifecycle") = error
            else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testStorageSourceNeverUsesRandomUUIDDecodeFallbacks() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageKit")
        let files = try XCTUnwrap(FileManager.default.enumerator(atPath: root.path))
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
        var offenders: [String] = []
        for file in files {
            let source = try String(
                contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in source.components(separatedBy: .newlines).enumerated()
            where line.contains("?? UUID()") {
                offenders.append("\(file):\(index + 1)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "Persisted UUID decoding must throw or diagnose; random fallbacks found: \(offenders)")
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

    // MARK: - Trash: restore and purge over tombstones

    func testTrashListsRestoresAndPurges() async throws {
        _ = try await seedMeetingWithTranscript()
        try await store.delete(meeting.id)

        // Listed in the trash, newest deletion first.
        let trash = try await store.deletedMeetings()
        XCTAssertEqual(trash.map(\.meeting.id), [meeting.id])

        // Restore brings the meeting AND its content back untouched.
        try await store.restore(meeting.id)
        let visible = try await store.meetings().map(\.id)
        XCTAssertEqual(visible, [meeting.id])
        let restored = try await store.detail(meeting.id)
        let detail = try XCTUnwrap(restored)
        XCTAssertFalse(detail.segments.isEmpty, "children come back with the meeting")
        let trashAfter = try await store.deletedMeetings()
        XCTAssertTrue(trashAfter.isEmpty)
    }

    func testPurgeRefusesLiveMeetingsAndErasesTombstonedOnes() async throws {
        _ = try await seedMeetingWithTranscript()

        // Purging a LIVE meeting is a no-op: the trash is the only door.
        try await store.purge(meeting.id)
        let liveCount = try await store.meetings().count
        XCTAssertEqual(liveCount, 1)

        try await store.delete(meeting.id)
        try await store.purge(meeting.id)
        let all = try await store.meetings(includeDeleted: true)
        XCTAssertTrue(all.isEmpty)
        let trash = try await store.deletedMeetings()
        XCTAssertTrue(trash.isEmpty)
        // FTS cleaned via GRDB triggers: no hits survive the purge.
        let hits = try await store.search("presupuesto")
        XCTAssertTrue(hits.isEmpty)
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

    func testMostRecentSummarySelectsLatestRecipeWithoutDeletingHistory() async throws {
        _ = try await seedMeetingWithTranscript()
        let general = SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "es",
            markdown: "# general",
            actionItems: [])
        let standup = SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.standup.id,
            language: "es",
            markdown: "# standup",
            actionItems: [ActionItem(text: "Unblock rollout")])

        try await store.saveSummary(general)
        try await store.saveSummary(standup)

        let active = try await store.mostRecentSummary(meeting.id)
        let retainedGeneral = try await store.summary(
            meeting.id,
            recipeID: Recipe.general.id,
            version: 1)
        XCTAssertEqual(active?.draft.recipeID, Recipe.standup.id)
        XCTAssertEqual(active?.draft.markdown, "# standup")
        XCTAssertEqual(active?.draft.actionItems.first?.text, "Unblock rollout")
        XCTAssertEqual(retainedGeneral?.draft.markdown, "# general")
    }

    /// D25: the fingerprint round-trips and `latestSummary(fingerprint:)`
    /// finds the cache hit (same language) or the translation pivot (any
    /// language); pre-fingerprint snapshots (NULL) never match.
    func testSummaryFingerprintMatchesCacheAndPivot() async throws {
        _ = try await seedMeetingWithTranscript()

        try await store.saveSummary(
            SummaryDraft(
                meetingID: meeting.id, recipeID: Recipe.general.id, language: "es",
                markdown: "# viejo sin fingerprint", actionItems: []))
        try await store.saveSummary(
            SummaryDraft(
                meetingID: meeting.id, recipeID: Recipe.general.id, language: "en",
                markdown: "# pivot", actionItems: [ActionItem(text: "ship it")],
                fingerprint: "f-abc"))

        // Exact hit: same fingerprint + language.
        let exact = try await store.latestSummary(
            meeting.id, fingerprint: "f-abc", language: "en")
        XCTAssertEqual(exact?.draft.markdown, "# pivot")
        XCTAssertEqual(exact?.draft.fingerprint, "f-abc")
        XCTAssertEqual(exact?.draft.actionItems.first?.text, "ship it")

        // Pivot: same fingerprint, no language pin.
        let pivot = try await store.latestSummary(meeting.id, fingerprint: "f-abc")
        XCTAssertEqual(pivot?.draft.language, "en")

        // No match: other language pin, other fingerprint, and NULL rows.
        let missES = try await store.latestSummary(
            meeting.id, fingerprint: "f-abc", language: "es")
        XCTAssertNil(missES, "the es snapshot has no fingerprint and must not match")
        let missOther = try await store.latestSummary(meeting.id, fingerprint: "f-zzz")
        XCTAssertNil(missOther)
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

    func testOpenActionItemsComeFromLatestSnapshotOnly() async throws {
        _ = try await seedMeetingWithTranscript()
        try await store.saveSummary(
            SummaryDraft(
                meetingID: meeting.id, recipeID: Recipe.general.id, language: "es",
                markdown: "# v1", actionItems: [ActionItem(text: "tarea vieja")]))
        let done = ActionItem(text: "tarea hecha", isDone: true)
        try await store.saveSummary(
            SummaryDraft(
                meetingID: meeting.id, recipeID: Recipe.general.id, language: "es",
                markdown: "# v2",
                actionItems: [ActionItem(text: "tarea vigente"), done]))

        let open = try await store.openActionItems()
        XCTAssertEqual(open.map(\.item.text), ["tarea vigente"])
        XCTAssertEqual(open.first?.meetingTitle, "Planning semanal")
    }

    func testDeleteAndRestoreScopeEveryLibraryAggregateThroughLiveMeetings() async throws {
        _ = try await seedMeetingWithTranscript()
        try await store.saveSummary(
            SummaryDraft(
                meetingID: meeting.id, recipeID: Recipe.general.id, language: "es",
                markdown: "# resumen",
                actionItems: [
                    ActionItem(text: "tarea abierta"),
                    ActionItem(text: "tarea hecha", isDone: true),
                ]))

        let before = try await store.libraryFacts()
        let beforeOpen = try await store.openActionItems()
        let beforeSummary = try await store.summary(meeting.id)
        let beforeFindings = try await store.findingInputs(for: [meeting.id])
        XCTAssertEqual(before.topParticipants.map(\.name), ["Ana"])
        XCTAssertEqual(before.openActionItems, 1)
        XCTAssertEqual(before.doneActionItems, 1)
        XCTAssertEqual(beforeOpen.count, 1)
        XCTAssertNotNil(beforeSummary)
        XCTAssertNotNil(beforeFindings[meeting.id])

        try await store.delete(meeting.id)
        let deleted = try await store.libraryFacts()
        let deletedOpen = try await store.openActionItems()
        let deletedSummary = try await store.summary(meeting.id)
        let deletedFindings = try await store.findingInputs(for: [meeting.id])
        XCTAssertTrue(deleted.topParticipants.isEmpty)
        XCTAssertEqual(deleted.openActionItems, 0)
        XCTAssertEqual(deleted.doneActionItems, 0)
        XCTAssertTrue(deletedOpen.isEmpty)
        XCTAssertNil(deletedSummary)
        XCTAssertNil(deletedFindings[meeting.id])

        try await store.restore(meeting.id)
        let restored = try await store.libraryFacts()
        let restoredOpen = try await store.openActionItems()
        let restoredSummary = try await store.summary(meeting.id)
        let restoredFindings = try await store.findingInputs(for: [meeting.id])
        XCTAssertEqual(restored, before)
        XCTAssertEqual(restoredOpen.count, 1)
        XCTAssertNotNil(restoredSummary)
        XCTAssertNotNil(restoredFindings[meeting.id])
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

    // MARK: - Quality re-pass (D7)

    func testReplaceCastRetiresOldTranscriptAndKeepsSummaries() async throws {
        _ = try await seedMeetingWithTranscript()
        try await store.saveSummary(
            SummaryDraft(
                meetingID: meeting.id, recipeID: Recipe.general.id, language: "es",
                markdown: "# v1", actionItems: []))

        let refined = Speaker(meetingID: meeting.id, label: "S1", displayName: "Ana")
        let newSegments = [
            TranscriptSegment(
                meetingID: meeting.id, speakerID: refined.id, channel: .system,
                text: "transcript refinado con whisper", startTime: 0, endTime: 5, isFinal: true)
        ]
        try await store.replaceCast(for: meeting.id, speakers: [refined], segments: newSegments)

        let detail = try await store.detail(meeting.id)
        XCTAssertEqual(detail?.segments.count, 1)
        XCTAssertEqual(detail?.segments.first?.text, "transcript refinado con whisper")
        XCTAssertEqual(detail?.speakers.map(\.label), ["S1"])
        // Summary snapshots survive the re-pass (immutable history, D4).
        XCTAssertEqual(detail?.summaries.count, 1)
        // Old segments are tombstones, not gone: FTS must not find them.
        let hits = try await store.search("presupuesto")
        XCTAssertTrue(hits.isEmpty)
        let refinedHits = try await store.search("whisper")
        XCTAssertEqual(refinedHits.count, 1)
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

extension MeetingStoreTests {
    func testContextItemsRoundTripAndTombstone() async throws {
        try await store.save(meeting)

        let first = ContextItem(
            meetingID: meeting.id, kind: .note, content: "pricing", timestamp: 60)
        let second = ContextItem(
            meetingID: meeting.id, kind: .link, content: "https://x.test", timestamp: 30)
        try await store.save([first, second])

        let items = try await store.contextItems(for: meeting.id)
        XCTAssertEqual(items.map(\.content), ["https://x.test", "pricing"])  // por timestamp
        XCTAssertEqual(items.map(\.kind), [.link, .note])

        try await store.deleteContextItem(first.id)
        let remaining = try await store.contextItems(for: meeting.id)
        XCTAssertEqual(remaining.map(\.content), ["https://x.test"])
    }

    func testCompanionCardsRoundTripAndTombstone() async throws {
        try await store.save(meeting)

        let first = CompanionCard(
            question: "¿Qué framework usamos?", answer: "SwiftUI", kind: .knowledge,
            source: "on-device", askedAt: 90)
        let second = CompanionCard(
            question: "¿Te acuerdas del presupuesto?", answer: "", kind: .context,
            source: "on-device", directed: true, askedAt: 40)
        try await store.save([first, second], for: meeting.id)

        let cards = try await store.companionCards(for: meeting.id)
        XCTAssertEqual(cards.map(\.question), [second.question, first.question])  // por askedAt
        XCTAssertEqual(cards.map(\.kind), [.context, .knowledge])
        XCTAssertEqual(cards.first?.directed, true)
        XCTAssertEqual(cards.last?.answer, "SwiftUI")

        try await store.deleteCompanionCard(first.id)
        let remaining = try await store.companionCards(for: meeting.id)
        XCTAssertEqual(remaining.map(\.question), [second.question])
    }

    func testReplaceCompanionCardsTombstonesTheOldSnapshot() async throws {
        try await store.save(meeting)
        try await store.save(
            [
                CompanionCard(
                    question: "vieja 1", answer: "a", kind: .knowledge, source: "on-device",
                    askedAt: 10),
                CompanionCard(
                    question: "vieja 2", answer: "b", kind: .context, source: "on-device",
                    askedAt: 20)
            ], for: meeting.id)

        // Refine re-derives a different set from the clean transcript.
        try await store.replaceCompanionCards(
            [
                CompanionCard(
                    question: "nueva", answer: "c", kind: .knowledge, source: "on-device",
                    askedAt: 15)
            ], for: meeting.id)

        let cards = try await store.companionCards(for: meeting.id)
        XCTAssertEqual(cards.map(\.question), ["nueva"])  // the old snapshot is gone
    }

    func testGeneratedCompanionReplacementLinksRunAndRetainsItOnCardSave() async throws {
        try await store.save(meeting)
        let card = CompanionCard(
            question: "What changed?", answer: "The provenance boundary.",
            kind: .context, source: "on-device", askedAt: 15)
        let run = companionRun(card: card, outcome: .succeeded)

        try await store.replaceCompanionCards(
            [],
            generated: [CompanionGenerationArtifact(card: card, generationRun: run)],
            for: meeting.id)

        let storedRuns = try await store.generationRuns(for: meeting.id)
        XCTAssertEqual(storedRuns, [run])
        try await store.save([card], for: meeting.id)
        let linkedRunID = try await store.database.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT generationRunID FROM companionCard WHERE id = ?",
                arguments: [card.id.uuidString])
        }
        XCTAssertEqual(linkedRunID, run.id.rawValue.uuidString)
    }

    func testGeneratedCompanionReplacementRollsBackRunAndOldSnapshotOnCardFailure() async throws {
        try await store.save(meeting)
        let old = CompanionCard(
            question: "Old card", answer: "Keep me", kind: .context,
            source: "on-device", askedAt: 5)
        try await store.save([old], for: meeting.id)
        try await store.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_generated_companion
                BEFORE INSERT ON companionCard
                WHEN NEW.question = 'New card'
                BEGIN
                    SELECT RAISE(ABORT, 'injected Companion failure');
                END
                """)
        }
        let card = CompanionCard(
            question: "New card", answer: "Never partial", kind: .knowledge,
            source: "on-device", askedAt: 10)
        let run = companionRun(card: card, outcome: .succeeded)

        do {
            try await store.replaceCompanionCards(
                [],
                generated: [CompanionGenerationArtifact(card: card, generationRun: run)],
                for: meeting.id)
            XCTFail("a late card failure must reject the whole replacement")
        } catch {
            let cards = try await store.companionCards(for: meeting.id)
            let runs = try await store.generationRuns(for: meeting.id)
            XCTAssertEqual(cards, [old])
            XCTAssertTrue(runs.isEmpty)
        }
    }

    func testGeneratedCompanionReplacementRejectsStaleTranscriptRevision() async throws {
        try await store.save(meeting)
        let card = CompanionCard(
            question: "Stale question", answer: "Must not publish",
            kind: .context, source: "on-device", askedAt: 15)
        let staleRun = companionRun(
            card: card,
            outcome: .succeeded,
            sourceTranscriptRevision: meeting.transcriptRevision + 1)

        do {
            try await store.replaceCompanionCards(
                [],
                generated: [CompanionGenerationArtifact(
                    card: card,
                    generationRun: staleRun)],
                for: meeting.id)
            XCTFail("stale Companion provenance must not replace the current snapshot")
        } catch let error as StorageError {
            guard case .invalidGenerationRun = error else {
                return XCTFail("expected invalidGenerationRun, got \(error)")
            }
        }

        let cards = try await store.companionCards(for: meeting.id)
        let runs = try await store.generationRuns(for: meeting.id)
        XCTAssertTrue(cards.isEmpty)
        XCTAssertTrue(runs.isEmpty)
    }

    func testCompanionTerminalRunRejectsStaleTranscriptRevision() async throws {
        try await store.save(meeting)
        let card = CompanionCard(
            question: "Failed question", answer: "",
            kind: .context, source: "on-device", askedAt: 15)
        let sourceRevision = meeting.transcriptRevision + 1
        let staleRun = companionRun(
            card: card,
            outcome: .failed,
            sourceTranscriptRevision: sourceRevision)

        do {
            try await store.saveCompanionGenerationRun(
                staleRun,
                workflow: "post-refine",
                sourceTranscriptRevision: sourceRevision)
            XCTFail("a stale terminal Companion run must not enter current history")
        } catch let error as StorageError {
            guard case .invalidGenerationRun = error else {
                return XCTFail("expected invalidGenerationRun, got \(error)")
            }
        }

        let runs = try await store.generationRuns(for: meeting.id)
        XCTAssertTrue(runs.isEmpty)
    }

    private func companionRun(
        card: CompanionCard,
        outcome: GenerationRunOutcome,
        sourceTranscriptRevision: Int = 0
    ) -> GenerationRun {
        let timestamp = meeting.startedAt.addingTimeInterval(card.askedAt)
        return GenerationRun(
            meetingID: meeting.id,
            kind: .companion,
            providerID: "foundation-models",
            modelID: "system-language-model",
            inputFingerprint: String(repeating: "e", count: 64),
            configJSON: """
                {"operation":"classify-and-answer",\
                "sourceTranscriptRevision":\(sourceTranscriptRevision),\
                "workflow":"post-refine"}
                """,
            outputLanguage: "en",
            startedAt: timestamp,
            finishedAt: timestamp.addingTimeInterval(1),
            outcome: outcome,
            metricsJSON: #"{"answerUTF8Bytes":12,"questionUTF8Bytes":12}"#)
    }
}
