import ApplicationKit
import GRDB
import PortavozCore
@testable import StorageKit
import XCTest

final class VoiceColumnsStorageTests: XCTestCase {
    private var store: MeetingStore!
    private let silence = VoiceColumns.silence

    override func setUpWithError() throws {
        store = try MeetingStore.inMemory()
    }

    private struct Fixture {
        let meeting: Meeting
        let me: Speaker
        let marta: Speaker
        let segments: [TranscriptSegment]
    }

    /// Marta speaks 0–40 s, you 40–100 s, Marta again 150–200 s.
    private func seed(title: String = "Weekly sync") async throws -> Fixture {
        let meeting = Meeting(title: title, startedAt: Date())
        try await store.save(meeting)
        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        var marta = Speaker(meetingID: meeting.id, label: "S1")
        marta.displayName = "Marta"
        try await store.save([me, marta])
        let segments = [
            TranscriptSegment(
                meetingID: meeting.id, speakerID: marta.id, channel: .system,
                text: "hola", startTime: 0, endTime: 40, isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id, speakerID: me.id, channel: .microphone,
                text: "hi", startTime: 40, endTime: 100, isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id, speakerID: marta.id, channel: .system,
                text: "vale", startTime: 150, endTime: 200, isFinal: true),
        ]
        try await store.save(segments)
        return Fixture(meeting: meeting, me: me, marta: marta, segments: segments)
    }

    private func cachedAt(_ id: MeetingID) async throws -> Date? {
        try await store.database.read { db in
            try Date.fetchOne(
                db, sql: "SELECT updatedAt FROM meetingVoiceColumns WHERE meetingID = ?",
                arguments: [id.rawValue.uuidString])
        }
    }

    private func strip(_ id: MeetingID) async throws -> MeetingVoiceColumns {
        let strips = try await store.voiceColumns(for: [id])
        return try XCTUnwrap(strips[id])
    }

    func testBatchedReadBuildsStripsForEveryMeeting() async throws {
        let first = try await seed()
        let second = try await seed(title: "Retro")
        let silent = Meeting(title: "No speech", startedAt: Date())
        try await store.save(silent)

        let strips = try await store.voiceColumns(for: [first.meeting.id, second.meeting.id, silent.id])

        XCTAssertEqual(Set(strips.keys), [first.meeting.id, second.meeting.id])
        let strip = try XCTUnwrap(strips[first.meeting.id])
        XCTAssertEqual(strip.duration, 200)
        XCTAssertEqual(strip.columns.count, VoiceColumns.storedCount)
        // One column per second: Marta 0–40, you 40–100, silence 100–150, Marta 150–200.
        XCTAssertEqual(strip.columns[0], 0)
        XCTAssertEqual(strip.columns[39], 0)
        XCTAssertEqual(strip.columns[40], 1)
        XCTAssertEqual(strip.columns[120], silence)
        XCTAssertEqual(strip.columns[199], 0)
        XCTAssertEqual(strip.voices.map(\.speakerID), [first.marta.id, first.me.id])
        XCTAssertEqual(strip.voices.map(\.displayName), ["Marta", nil])
        XCTAssertEqual(strip.voices.map(\.isMe), [false, true])
        XCTAssertEqual(strip.voices.map(\.talkSeconds), [90, 60])
        XCTAssertEqual(strip.voices.map(\.firstHeard), [0, 40])
        let empty = try await store.voiceColumns(for: [])
        XCTAssertTrue(empty.isEmpty)
    }

    func testStripsAreCachedUntilTheTranscriptChanges() async throws {
        let fixture = try await seed()
        _ = try await store.voiceColumns(for: [fixture.meeting.id])
        let cached = try await cachedAt(fixture.meeting.id)
        XCTAssertNotNil(cached)
        _ = try await store.voiceColumns(for: [fixture.meeting.id])
        let reread = try await cachedAt(fixture.meeting.id)
        XCTAssertEqual(reread, cached)

        try await store.save([TranscriptSegment(
            meetingID: fixture.meeting.id, speakerID: fixture.me.id, channel: .microphone,
            text: "one more", startTime: 100, endTime: 150, isFinal: true)])
        let dropped = try await cachedAt(fixture.meeting.id)
        XCTAssertNil(dropped)
        let strip = try await strip(fixture.meeting.id)
        XCTAssertEqual(strip.columns[120], 1)
    }

    func testSpeakerSavedAfterItsSegmentsRedrawsTheStrip() async throws {
        let fixture = try await seed()
        let late = SpeakerID()
        try await store.save([TranscriptSegment(
            meetingID: fixture.meeting.id, speakerID: late, channel: .system,
            text: "tarde", startTime: 100, endTime: 150, isFinal: true)])
        let before = try await strip(fixture.meeting.id)
        XCTAssertEqual(before.columns[120], silence)

        try await store.save([Speaker(id: late, meetingID: fixture.meeting.id, label: "S2")])
        let after = try await strip(fixture.meeting.id)
        XCTAssertEqual(after.voices.map(\.speakerID), [fixture.marta.id, fixture.me.id, late])
        XCTAssertEqual(after.columns[120], 2)
    }

    func testRenameShowsWithoutRebuilding() async throws {
        let fixture = try await seed()
        _ = try await store.voiceColumns(for: [fixture.meeting.id])
        let cached = try await cachedAt(fixture.meeting.id)
        var renamed = fixture.marta
        renamed.displayName = "Marta Ruiz"
        try await store.save([renamed])

        let strip = try await strip(fixture.meeting.id)
        XCTAssertEqual(strip.voices.first?.displayName, "Marta Ruiz")
        let reread = try await cachedAt(fixture.meeting.id)
        XCTAssertEqual(reread, cached)
    }

    func testSpeakerCorrectionsAndSuppressionsRedrawTheStrip() async throws {
        let fixture = try await seed()
        _ = try await store.voiceColumns(for: [fixture.meeting.id])
        let revision = fixture.meeting.transcriptRevision
        _ = try await store.appendTranscriptCorrections([
            TranscriptCorrectionEvent(
                meetingID: fixture.meeting.id, baseTranscriptRevision: revision,
                targetSegmentIDs: [fixture.segments[0].id], kind: .changeSpeaker(fixture.me.id),
                sourceDeviceID: UUID(), createdAt: Date(timeIntervalSince1970: 10)),
            TranscriptCorrectionEvent(
                meetingID: fixture.meeting.id, baseTranscriptRevision: revision,
                targetSegmentIDs: [fixture.segments[2].id], kind: .suppress,
                sourceDeviceID: UUID(), createdAt: Date(timeIntervalSince1970: 10)),
        ])
        let rebuiltInTheSameWrite = try await cachedAt(fixture.meeting.id)
        XCTAssertNotNil(rebuiltInTheSameWrite)

        let strip = try await strip(fixture.meeting.id)
        XCTAssertEqual(strip.voices.map(\.speakerID), [fixture.me.id])
        XCTAssertEqual(strip.voices.first?.talkSeconds, 100)
        XCTAssertEqual(strip.duration, 100)
        XCTAssertEqual(Set(strip.columns), [0])
    }

    func testSplitPartsCarryTheirOwnSpeakers() async throws {
        let fixture = try await seed()
        _ = try await store.appendTranscriptCorrection(TranscriptCorrectionEvent(
            meetingID: fixture.meeting.id, baseTranscriptRevision: fixture.meeting.transcriptRevision,
            targetSegmentIDs: [fixture.segments[1].id],
            kind: .split([
                TranscriptCorrectionPart(
                    text: "hi", speakerID: fixture.me.id, language: nil, startTime: 40, endTime: 50),
                TranscriptCorrectionPart(
                    text: "there", speakerID: fixture.marta.id, language: nil, startTime: 50, endTime: 100),
            ]),
            sourceDeviceID: UUID(), createdAt: Date(timeIntervalSince1970: 10)))

        let strip = try await strip(fixture.meeting.id)
        XCTAssertEqual(strip.voices.map(\.talkSeconds), [140, 10])
        XCTAssertEqual(strip.columns[45], 1)
        XCTAssertEqual(strip.columns[60], 0)
    }

    func testAudioLengthSetsTheTimeline() async throws {
        let fixture = try await seed()
        _ = try await store.voiceColumns(for: [fixture.meeting.id])
        try await store.database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audioAsset
                        (id, meetingID, channel, role, relativePath, durationSeconds, createdAt, updatedAt)
                    VALUES (?, ?, 'microphone', 'original', ?, 400, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString, fixture.meeting.id.rawValue.uuidString,
                    "\(UUID().uuidString)/mic.caf", Date(), Date(),
                ])
        }
        let strip = try await strip(fixture.meeting.id)
        XCTAssertEqual(strip.duration, 400)
        XCTAssertEqual(strip.columns[0], 0)
        XCTAssertEqual(strip.columns[60], silence)
    }

    func testTombstonedMeetingsAreAbsentUntilRestored() async throws {
        let fixture = try await seed()
        try await store.delete(fixture.meeting.id)
        let deleted = try await store.voiceColumns(for: [fixture.meeting.id])
        XCTAssertTrue(deleted.isEmpty)
        try await store.restore(fixture.meeting.id)
        let restored = try await store.voiceColumns(for: [fixture.meeting.id])
        XCTAssertNotNil(restored[fixture.meeting.id])
    }

    func testRefinedCastStoresItsStripInTheSameWrite() async throws {
        let fixture = try await seed()
        let s2 = Speaker(meetingID: fixture.meeting.id, label: "S2")
        try await store.applyRefinedCast(
            for: fixture.meeting.id,
            expectedTranscriptRevision: fixture.meeting.transcriptRevision,
            language: "es",
            speakers: [fixture.me, s2],
            segments: [TranscriptSegment(
                meetingID: fixture.meeting.id, speakerID: s2.id, channel: .system,
                text: "nuevo", startTime: 0, endTime: 30, isFinal: true)])

        let cached = try await cachedAt(fixture.meeting.id)
        XCTAssertNotNil(cached)
        let strip = try await strip(fixture.meeting.id)
        XCTAssertEqual(strip.voices.map(\.speakerID), [s2.id])
    }

    func testDetailBinningMatchesTheStoredStrip() async throws {
        let fixture = try await seed()
        let stored = try await strip(fixture.meeting.id)
        let detail = MeetingVoiceColumns(
            speakers: [fixture.me, fixture.marta], segments: fixture.segments,
            duration: 0, count: VoiceColumns.storedCount)
        XCTAssertEqual(detail, stored)

        let cast = VoiceCast(columns: stored)
        XCTAssertEqual(cast.tints(for: stored), [cast.tint(for: fixture.marta), .you])
        XCTAssertNotEqual(cast.tint(for: fixture.marta), .grey)
    }

    func testExistingMeetingsFillLazilyAfterTheUpgrade() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-voice-columns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("portavoz.sqlite")
        let meetingID = MeetingID()
        let speakerID = SpeakerID()
        var legacy: DatabaseQueue? = try DatabaseQueue(path: url.path)
        try StorageSchema.migrator().migrate(try XCTUnwrap(legacy), upTo: "v60")
        try await legacy?.write { db in
            let now = Date()
            try db.execute(
                sql: """
                    INSERT INTO meeting (id, title, startedAt, retention, createdAt, updatedAt)
                    VALUES (?, 'Before the strip', ?, 'keep', ?, ?)
                    """,
                arguments: [meetingID.rawValue.uuidString, now, now, now])
            try db.execute(
                sql: """
                    INSERT INTO speaker (id, meetingID, label, isMe, createdAt, updatedAt)
                    VALUES (?, ?, 'Me', 1, ?, ?)
                    """,
                arguments: [speakerID.rawValue.uuidString, meetingID.rawValue.uuidString, now, now])
            try db.execute(
                sql: """
                    INSERT INTO segment
                        (id, meetingID, speakerID, channel, text, startTime, endTime, isFinal,
                         createdAt, updatedAt)
                    VALUES (?, ?, ?, 'microphone', 'hi', 0, 10, 1, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString, meetingID.rawValue.uuidString,
                    speakerID.rawValue.uuidString, now, now,
                ])
        }
        legacy = nil

        let upgraded = try MeetingStore(databaseURL: url)
        let before = try await upgraded.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetingVoiceColumns")
        }
        XCTAssertEqual(before, 0)
        let strips = try await upgraded.voiceColumns(for: [meetingID])
        XCTAssertEqual(strips[meetingID]?.voices.map(\.speakerID), [speakerID])
        XCTAssertEqual(Set(strips[meetingID]?.columns ?? []), [0])
    }

    func testALaterMigrationThatTouchesSegmentsLeavesNoOrphanVoices() throws {
        let database = try DatabaseQueue()
        try StorageSchema.migrator().migrate(database)
        try database.write { db in
            let now = Date()
            let meeting = UUID().uuidString
            let speaker = UUID().uuidString
            try db.execute(
                sql: """
                    INSERT INTO meeting (id, title, startedAt, retention, createdAt, updatedAt)
                    VALUES (?, 'Cached', ?, 'keep', ?, ?)
                    """,
                arguments: [meeting, now, now, now])
            try db.execute(
                sql: """
                    INSERT INTO speaker (id, meetingID, label, isMe, createdAt, updatedAt)
                    VALUES (?, ?, 'Me', 1, ?, ?)
                    """,
                arguments: [speaker, meeting, now, now])
            try db.execute(
                sql: """
                    INSERT INTO segment
                        (id, meetingID, speakerID, channel, text, startTime, endTime, isFinal,
                         createdAt, updatedAt)
                    VALUES (?, ?, ?, 'microphone', 'hi', 0, 10, 1, ?, ?)
                    """,
                arguments: [UUID().uuidString, meeting, speaker, now, now])
            try MeetingStore.refreshVoiceColumns(
                in: db, for: [MeetingID(rawValue: try XCTUnwrap(UUID(uuidString: meeting)))])
        }
        var later = StorageSchema.migrator()
        later.registerMigration("later") { db in
            try db.execute(sql: "UPDATE segment SET endTime = endTime + 1")
        }

        XCTAssertNoThrow(try later.migrate(database))
        let orphans = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetingVoiceColumnsVoice")
        }
        XCTAssertEqual(orphans, 0)
    }

    func testATailTrimShortensTheStripTimeline() async throws {
        let meeting = Meeting(
            title: "Trimmed", startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 50))
        try await store.save(meeting)
        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        try await store.save([me])
        try await store.save([TranscriptSegment(
            meetingID: meeting.id, speakerID: me.id, channel: .microphone,
            text: "hola", startTime: 0, endTime: 40, isFinal: true)])
        try await store.database.write { db in
            try db.execute(sql: """
                INSERT INTO audioAsset
                    (id, meetingID, channel, role, relativePath, durationSeconds, createdAt, updatedAt)
                VALUES (?, ?, 'mic', 'capture', 'trim/mic.caf', 100, ?, ?)
                """, arguments: [UUID().uuidString, meeting.id.rawValue.uuidString, Date(), Date()])
        }

        let trimmed = try await strip(meeting.id)
        XCTAssertEqual(trimmed.duration, 50, "the asset still says 100 s after the trim")
        XCTAssertEqual(trimmed.columns[180], silence)
        XCTAssertEqual(trimmed.columns[100], 0)
    }
}
