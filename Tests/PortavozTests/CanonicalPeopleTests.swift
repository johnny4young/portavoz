import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class CanonicalPeopleTests: XCTestCase {
    func testAliasNormalizationIsStableButNeverAUniqueIdentity() {
        XCTAssertEqual(
            PersonAliasNormalizer.displayName("  Ána\t García  "),
            "Ána García")
        XCTAssertEqual(
            PersonAliasNormalizer.normalize("  ÁNA\nＧarcía  "),
            "ana garcia")
        XCTAssertNil(PersonAliasNormalizer.normalize(" \n\t "))
    }

    func testV7MigratesAdditivelyToCanonicalPeopleSchema() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v7")
        let meetingID = UUID().uuidString
        let speakerID = UUID().uuidString
        let timestamp = Date(timeIntervalSince1970: 1_783_695_600)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meeting (
                        id, title, startedAt, retention, visibility,
                        createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    meetingID, "Legacy identity", timestamp,
                    try MeetingRecord.encode(.keep), "private", timestamp, timestamp,
                ])
            try db.execute(
                sql: """
                    INSERT INTO speaker (
                        id, meetingID, label, isMe, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [speakerID, meetingID, "S1", false, timestamp, timestamp])
        }

        try migrator.migrate(database)

        try database.read { db in
            XCTAssertEqual(StorageSchema.version, 10)
            XCTAssertEqual(
                try String.fetchAll(
                    db,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"),
                ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10"])
            XCTAssertEqual(
                try Set(db.columns(in: "person").map(\.name)),
                ["id", "preferredName", "createdAt", "updatedAt", "deletedAt"])
            XCTAssertEqual(
                try Set(db.columns(in: "personAlias").map(\.name)),
                [
                    "id", "personID", "normalizedAlias", "source", "confidence",
                    "createdAt", "updatedAt", "deletedAt",
                ])
            XCTAssertTrue(try Set(db.columns(in: "speaker").map(\.name)).contains("personID"))
            XCTAssertNil(try String.fetchOne(
                db,
                sql: "SELECT personID FROM speaker WHERE id = ?",
                arguments: [speakerID]))
            let speakerForeignKeys = try Row.fetchAll(
                db,
                sql: "PRAGMA foreign_key_list(speaker)")
            XCTAssertEqual(
                Set(speakerForeignKeys.map { $0["table"] as String }),
                ["meeting", "person"])
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testExplicitCreateAndExistingLinksAreAtomicAndCandidateOnly() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Planning", startedAt: Date())
        let first = Speaker(meetingID: meeting.id, label: "S1")
        let second = Speaker(meetingID: meeting.id, label: "S2")
        let third = Speaker(meetingID: meeting.id, label: "S3")
        try await store.save(meeting)
        try await store.save([first, second, third])

        let ana = try await store.createPersonAndLink(
            speakerID: first.id,
            preferredName: "  Ána   García ",
            source: .manualName)
        XCTAssertEqual(ana.person.preferredName, "Ána García")
        XCTAssertEqual(ana.speaker.personID, ana.person.id)
        XCTAssertEqual(ana.speaker.displayName, "Ána García")

        let candidates = try await store.people(matchingAlias: "ana garcia")
        XCTAssertEqual(candidates.map(\.id), [ana.person.id])

        let distinct = try await store.createPersonAndLink(
            speakerID: second.id,
            preferredName: "Ana García",
            source: .transcriptSuggestion)
        XCTAssertNotEqual(distinct.person.id, ana.person.id)
        let duplicateCandidates = try await store.people(matchingAlias: "ÁNA GARCÍA")
        XCTAssertEqual(
            Set(duplicateCandidates.map(\.id)),
            [ana.person.id, distinct.person.id])

        let linked = try await store.linkSpeaker(
            third.id,
            to: ana.person.id,
            observedAlias: "Ana G",
            source: .voiceSuggestion)
        XCTAssertEqual(linked.person.id, ana.person.id)
        XCTAssertEqual(linked.speaker.displayName, "Ána García")
        let shortAliasCandidates = try await store.people(matchingAlias: "ana g")
        XCTAssertEqual(
            shortAliasCandidates.map(\.id),
            [ana.person.id])

        let storedDetail = try await store.detail(meeting.id)
        let detail = try XCTUnwrap(storedDetail)
        XCTAssertEqual(
            detail.speakers.first(where: { $0.id == first.id })?.personID,
            ana.person.id)
        XCTAssertEqual(
            detail.speakers.first(where: { $0.id == second.id })?.personID,
            distinct.person.id)
        let persistedSources = try await store.database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT source FROM personAlias ORDER BY source")
        }
        XCTAssertEqual(
            persistedSources,
            ["manual-name", "transcript-suggestion", "voice-suggestion"])
    }

    func testInvalidOrStaleLinksLeaveNoPartialPerson() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Planning", startedAt: Date())
        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        let participant = Speaker(meetingID: meeting.id, label: "S1")
        try await store.save(meeting)
        try await store.save([me, participant])

        await XCTAssertThrowsErrorAsync {
            _ = try await store.createPersonAndLink(
                speakerID: me.id,
                preferredName: "Me",
                source: .manualName)
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await store.linkSpeaker(
                participant.id,
                to: PersonID(),
                observedAlias: "Unknown",
                source: .manualName)
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await store.createPersonAndLink(
                speakerID: participant.id,
                preferredName: "   ",
                source: .manualName)
        }

        let counts = try await store.database.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM person") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM personAlias") ?? -1)
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        let storedDetail = try await store.detail(meeting.id)
        let detail = try XCTUnwrap(storedDetail)
        XCTAssertNil(
            detail.speakers.first(where: { $0.id == participant.id })?.personID)
    }
}

private func XCTAssertThrowsErrorAsync(
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
