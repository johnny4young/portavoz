import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class StorageUpgradeTests: XCTestCase {
    private static let expectedMigrations = (1...StorageSchema.version).map { "v\($0)" }

    func testCleanInstallCreatesLatestSchemaAndReopensIdempotently() async throws {
        let root = try temporaryRoot(named: "clean-install")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("portavoz.sqlite")
        let meeting = Meeting(
            title: "Clean install",
            startedAt: Date(timeIntervalSince1970: 1_784_000_000),
            language: "es",
            audioDirectory: "Audio/clean-install")

        var store: MeetingStore? = try MeetingStore(databaseURL: databaseURL)
        try await assertHealthyLatestSchema(try XCTUnwrap(store))
        try await store?.save(meeting)
        let savedDetail = try await store?.detail(meeting.id)
        XCTAssertEqual(savedDetail?.meeting.title, "Clean install")

        store = nil
        store = try MeetingStore(databaseURL: databaseURL)
        let reopened = try XCTUnwrap(store)
        try await assertHealthyLatestSchema(reopened)
        let reopenedDetail = try await reopened.detail(meeting.id)
        let detail = try XCTUnwrap(reopenedDetail)
        XCTAssertEqual(detail.meeting.id, meeting.id)
        XCTAssertEqual(detail.meeting.audioDirectory, "Audio/clean-install")
    }

    func testV060LibraryMigratesToLatestWithoutChangingUserContent() async throws {
        let root = try temporaryRoot(named: "v060-upgrade")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("portavoz.sqlite")
        let fixture = try seedV060Library(at: databaseURL)

        var store: MeetingStore? = try MeetingStore(databaseURL: databaseURL)
        let upgraded = try XCTUnwrap(store)
        try await assertHealthyLatestSchema(upgraded)
        try await assertV060Content(fixture, in: upgraded)

        store = nil
        store = try MeetingStore(databaseURL: databaseURL)
        let reopened = try XCTUnwrap(store)
        try await assertHealthyLatestSchema(reopened)
        try await assertV060Content(fixture, in: reopened)
    }

    private func temporaryRoot(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func assertHealthyLatestSchema(
        _ store: MeetingStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let expectedMigrations = Self.expectedMigrations
        try await store.database.read { database in
            XCTAssertEqual(
                try String.fetchAll(
                    database,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"),
                expectedMigrations,
                file: file,
                line: line)
            XCTAssertEqual(
                try String.fetchOne(database, sql: "PRAGMA integrity_check"),
                "ok",
                file: file,
                line: line)
            XCTAssertTrue(
                try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty,
                file: file,
                line: line)
        }
    }

    private struct V060Fixture {
        let meetingID: MeetingID
        let mySpeakerID: SpeakerID
        let otherSpeakerID: SpeakerID
        let spanishSegmentID: UUID
        let englishSegmentID: UUID
        let actionItemID: UUID
        let contextItemID: UUID
        let companionCardID: UUID
    }

    private func seedV060Library(at databaseURL: URL) throws -> V060Fixture {
        let database = try DatabaseQueue(path: databaseURL.path)
        try StorageSchema.migrator().migrate(database, upTo: "v5")
        let fixture = V060Fixture(
            meetingID: MeetingID(),
            mySpeakerID: SpeakerID(),
            otherSpeakerID: SpeakerID(),
            spanishSegmentID: UUID(),
            englishSegmentID: UUID(),
            actionItemID: UUID(),
            contextItemID: UUID(),
            companionCardID: UUID())
        let summaryID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_752_000_000)

        try database.write { db in
            try insertLegacyMeeting(fixture, timestamp: timestamp, in: db)
            try insertLegacyCast(fixture, timestamp: timestamp, in: db)
            try insertLegacyTranscript(fixture, timestamp: timestamp, in: db)
            try insertLegacySummary(
                fixture,
                summaryID: summaryID,
                timestamp: timestamp,
                in: db)
            try insertLegacyReviewArtifacts(fixture, timestamp: timestamp, in: db)
        }

        try database.read { db in
            XCTAssertEqual(
                try String.fetchAll(
                    db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"),
                ["v1", "v2", "v3", "v4", "v5"])
        }
        return fixture
    }

    private func insertLegacyMeeting(
        _ fixture: V060Fixture,
        timestamp: Date,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO meeting (
                    id, title, startedAt, endedAt, language, audioDirectory,
                    retention, visibility, createdAt, updatedAt, deletedAt
                ) VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, NULL)
                """,
            arguments: [
                fixture.meetingID.rawValue.uuidString,
                "Bilingual launch review",
                timestamp,
                timestamp.addingTimeInterval(1_800),
                "Audio/bilingual-launch-review",
                try MeetingRecord.encode(.keep),
                "private",
                timestamp,
                timestamp
            ])
    }

    private func insertLegacyCast(
        _ fixture: V060Fixture,
        timestamp: Date,
        in db: Database
    ) throws {
        let meetingKey = fixture.meetingID.rawValue.uuidString
        try db.execute(
            sql: """
                INSERT INTO speaker (
                    id, meetingID, label, displayName, isMe,
                    createdAt, updatedAt, deletedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL),
                         (?, ?, ?, ?, ?, ?, ?, NULL)
                """,
            arguments: [
                fixture.mySpeakerID.rawValue.uuidString,
                meetingKey,
                "Me",
                "Johnny",
                true,
                timestamp,
                timestamp,
                fixture.otherSpeakerID.rawValue.uuidString,
                meetingKey,
                "S1",
                "Alex",
                false,
                timestamp,
                timestamp
            ])
    }

    private func insertLegacyTranscript(
        _ fixture: V060Fixture,
        timestamp: Date,
        in db: Database
    ) throws {
        let meetingKey = fixture.meetingID.rawValue.uuidString
        try db.execute(
            sql: """
                INSERT INTO segment (
                    id, meetingID, speakerID, channel, text, language,
                    startTime, endTime, confidence, isFinal,
                    createdAt, updatedAt, deletedAt, embedding
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL),
                         (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL)
                """,
            arguments: [
                fixture.spanishSegmentID.uuidString,
                meetingKey,
                fixture.mySpeakerID.rawValue.uuidString,
                AudioChannel.microphone.rawValue,
                "Mantengamos el idioma de cada persona.",
                "es",
                3.0,
                7.0,
                0.97,
                true,
                timestamp,
                timestamp,
                fixture.englishSegmentID.uuidString,
                meetingKey,
                fixture.otherSpeakerID.rawValue.uuidString,
                AudioChannel.system.rawValue,
                "Yes, preserve the language that was actually spoken.",
                "en",
                8.0,
                13.0,
                0.96,
                true,
                timestamp,
                timestamp
            ])
    }

    private func insertLegacySummary(
        _ fixture: V060Fixture,
        summaryID: UUID,
        timestamp: Date,
        in db: Database
    ) throws {
        let meetingKey = fixture.meetingID.rawValue.uuidString
        try db.execute(
            sql: """
                INSERT INTO summary (
                    id, meetingID, recipeID, language, markdown, version,
                    createdAt, deletedAt, fingerprint
                ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?)
                """,
            arguments: [
                summaryID.uuidString,
                meetingKey,
                Recipe.general.id,
                "en",
                "## Overview\n\nThe team will preserve each speaker's language.",
                1,
                timestamp,
                "sha256:v060-fixture"
            ])
        try db.execute(
            sql: """
                INSERT INTO actionItem (
                    id, summaryID, meetingID, text, ownerSpeakerID, isDone,
                    createdAt, updatedAt, deletedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
                """,
            arguments: [
                fixture.actionItemID.uuidString,
                summaryID.uuidString,
                meetingKey,
                "Validate one bilingual call.",
                fixture.mySpeakerID.rawValue.uuidString,
                false,
                timestamp,
                timestamp
            ])
    }

    private func insertLegacyReviewArtifacts(
        _ fixture: V060Fixture,
        timestamp: Date,
        in db: Database
    ) throws {
        let meetingKey = fixture.meetingID.rawValue.uuidString
        try db.execute(
            sql: """
                INSERT INTO contextItem (
                    id, meetingID, kind, content, timestamp,
                    createdAt, updatedAt, deletedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                """,
            arguments: [
                fixture.contextItemID.uuidString,
                meetingKey,
                ContextItem.Kind.note.rawValue,
                "Do not translate transcript turns.",
                14.0,
                timestamp,
                timestamp
            ])
        try db.execute(
            sql: """
                INSERT INTO companionCard (
                    id, meetingID, question, answer, kind, source, directed,
                    askedAt, createdAt, updatedAt, deletedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                """,
            arguments: [
                fixture.companionCardID.uuidString,
                meetingKey,
                "What is the transcript rule?",
                "Preserve the language actually spoken.",
                CompanionCard.Kind.context.rawValue,
                "on-device",
                true,
                15.0,
                timestamp,
                timestamp
            ])
    }

    private func assertV060Content(
        _ fixture: V060Fixture,
        in store: MeetingStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let storedDetail = try await store.detail(fixture.meetingID)
        let detail = try XCTUnwrap(
            storedDetail,
            file: file,
            line: line)
        assertLegacyMeetingAndTranscript(
            detail,
            fixture: fixture,
            file: file,
            line: line)

        let storedSummary = try await store.summary(fixture.meetingID)
        let summary = try XCTUnwrap(
            storedSummary,
            file: file,
            line: line)
        assertLegacySummary(summary, fixture: fixture, file: file, line: line)

        let context = try await store.contextItems(for: fixture.meetingID)
        XCTAssertEqual(context.map(\.id), [fixture.contextItemID], file: file, line: line)
        XCTAssertEqual(
            context.map(\.content),
            ["Do not translate transcript turns."],
            file: file,
            line: line)
        let cards = try await store.companionCards(for: fixture.meetingID)
        XCTAssertEqual(cards.map(\.id), [fixture.companionCardID], file: file, line: line)
        XCTAssertEqual(
            cards.map(\.answer),
            ["Preserve the language actually spoken."],
            file: file,
            line: line)

        try await store.database.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetingSyncState"),
                0,
                "upgrading must not silently opt an existing library into sync",
                file: file,
                line: line)
        }
    }

    private func assertLegacyMeetingAndTranscript(
        _ detail: MeetingDetail,
        fixture: V060Fixture,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(detail.meeting.title, "Bilingual launch review", file: file, line: line)
        XCTAssertNil(detail.meeting.language, file: file, line: line)
        XCTAssertEqual(
            detail.meeting.audioDirectory,
            "Audio/bilingual-launch-review",
            file: file,
            line: line)
        XCTAssertEqual(detail.meeting.lifecycleState, .ready, file: file, line: line)
        XCTAssertEqual(detail.meeting.transcriptRevision, 0, file: file, line: line)
        XCTAssertEqual(Set(detail.speakers.map(\.id)), [
            fixture.mySpeakerID,
            fixture.otherSpeakerID
        ], file: file, line: line)
        XCTAssertEqual(detail.segments.map(\.id), [
            fixture.spanishSegmentID,
            fixture.englishSegmentID
        ], file: file, line: line)
        XCTAssertEqual(detail.segments.map(\.language), ["es", "en"], file: file, line: line)
        XCTAssertEqual(
            detail.segments.map(\.text),
            [
                "Mantengamos el idioma de cada persona.",
                "Yes, preserve the language that was actually spoken."
            ],
            file: file,
            line: line)
    }

    private func assertLegacySummary(
        _ summary: (draft: SummaryDraft, version: Int),
        fixture: V060Fixture,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(summary.version, 1, file: file, line: line)
        XCTAssertEqual(summary.draft.language, "en", file: file, line: line)
        XCTAssertEqual(
            summary.draft.markdown,
            "## Overview\n\nThe team will preserve each speaker's language.",
            file: file,
            line: line)
        XCTAssertEqual(summary.draft.actionItems.map(\.id), [fixture.actionItemID], file: file, line: line)
        XCTAssertEqual(
            summary.draft.actionItems.map(\.text),
            ["Validate one bilingual call."],
            file: file,
            line: line)
    }
}
