import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class TranscriptCorrectionStorageTests: XCTestCase {
    private let sourceDeviceID = UUID(
        uuidString: "00000000-0000-4000-9000-000000000001")!

    func testEveryCorrectionKindRoundTripsThroughTypedTablesAndEnvelope() async throws {
        let fixture = try await makeFixture(segmentCount: 6)
        let events = [
            event(
                101,
                fixture: fixture,
                targets: [fixture.segments[0].id],
                kind: .replaceText(text: "Corrected", language: "en")),
            event(
                102,
                fixture: fixture,
                targets: [fixture.segments[1].id],
                kind: .changeSpeaker(fixture.secondSpeaker.id)),
            event(
                103,
                fixture: fixture,
                targets: [fixture.segments[2].id],
                kind: .split([
                    part(301, text: "Part one", start: 6, end: 7),
                    part(302, text: "Part two", start: 7, end: 8),
                ])),
            event(
                104,
                fixture: fixture,
                targets: [fixture.segments[3].id, fixture.segments[4].id],
                kind: .merge(replacementText: "Merged", language: "en")),
            event(
                105,
                fixture: fixture,
                targets: [fixture.segments[5].id],
                kind: .suppress),
        ]
        let syncGenerationBefore = try await localSyncGeneration(fixture)

        for event in events.reversed() {
            let persisted = try await fixture.store.appendTranscriptCorrection(event)
            XCTAssertEqual(persisted, event)
        }

        let expected = events.sorted(by: TranscriptCorrectionPolicy.precedes)
        let history = try await fixture.store.transcriptCorrectionHistory(
            for: fixture.meeting.id)
        XCTAssertEqual(history, expected)
        let envelope = try await fixture.store.transcriptCorrectionSyncEnvelope(
            for: fixture.meeting.id)
        XCTAssertEqual(envelope.events, expected)
        XCTAssertEqual(
            try JSONDecoder().decode(
                TranscriptCorrectionSyncEnvelope.self,
                from: JSONEncoder().encode(envelope)),
            envelope)
        let syncGenerationAfter = try await localSyncGeneration(fixture)
        XCTAssertEqual(syncGenerationAfter, syncGenerationBefore + events.count)

        try await fixture.store.database.read { database in
            XCTAssertEqual(
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM transcriptCorrection"),
                5)
            XCTAssertEqual(
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM transcriptCorrectionTarget"),
                6)
            XCTAssertEqual(
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM transcriptCorrectionPayload"),
                3)
            XCTAssertEqual(
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM transcriptCorrectionPart"),
                2)
        }
    }

    func testAtomicBatchPersistsCompatibleTextAndSpeakerCorrections() async throws {
        let fixture = try await makeFixture(segmentCount: 1)
        let source = fixture.segments[0]
        let text = event(
            101,
            fixture: fixture,
            targets: [source.id],
            kind: .replaceText(text: "Corrected", language: "en"))
        let speaker = event(
            102,
            fixture: fixture,
            targets: [source.id],
            kind: .changeSpeaker(fixture.secondSpeaker.id))
        let generationBefore = try await localSyncGeneration(fixture)

        let persisted = try await fixture.store.appendTranscriptCorrections([text, speaker])

        XCTAssertEqual(persisted, [text, speaker])
        let history = try await fixture.store.transcriptCorrectionHistory(
            for: fixture.meeting.id)
        XCTAssertEqual(history, [text, speaker])
        let composition = try ComposeTranscript().execute(
            baseTranscriptRevision: fixture.meeting.transcriptRevision,
            baseMaterial: .refined,
            segments: fixture.segments,
            corrections: history)
        XCTAssertEqual(composition.composed.rows.map(\.text), ["Corrected"])
        XCTAssertEqual(
            composition.composed.rows.map(\.speakerID),
            [fixture.secondSpeaker.id])
        let generationAfter = try await localSyncGeneration(fixture)
        XCTAssertEqual(generationAfter, generationBefore + 2)
    }

    func testAtomicBatchRollsBackEveryEventWhenOneDomainIsInvalid() async throws {
        let fixture = try await makeFixture(segmentCount: 1)
        let foreignMeeting = Meeting(
            title: "Foreign",
            startedAt: date(1),
            transcriptRevision: fixture.meeting.transcriptRevision)
        let foreignSpeaker = Speaker(meetingID: foreignMeeting.id, label: "S9")
        try await fixture.store.save(foreignMeeting)
        try await fixture.store.save([foreignSpeaker])
        let text = event(
            101,
            fixture: fixture,
            targets: [fixture.segments[0].id],
            kind: .replaceText(text: "Must roll back", language: "en"))
        let invalidSpeaker = event(
            102,
            fixture: fixture,
            targets: [fixture.segments[0].id],
            kind: .changeSpeaker(foreignSpeaker.id))
        let generationBefore = try await localSyncGeneration(fixture)

        await assertInvalidCorrection {
            _ = try await fixture.store.appendTranscriptCorrections([text, invalidSpeaker])
        }

        let history = try await fixture.store.transcriptCorrectionHistory(
            for: fixture.meeting.id)
        XCTAssertTrue(history.isEmpty)
        let generationAfter = try await localSyncGeneration(fixture)
        XCTAssertEqual(generationAfter, generationBefore)
        try await fixture.store.database.read { database in
            XCTAssertEqual(
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM transcriptCorrection"),
                0)
        }

        await assertInvalidCorrection {
            _ = try await fixture.store.appendTranscriptCorrections([text, text])
        }
        let historyAfterDuplicate = try await fixture.store.transcriptCorrectionHistory(
            for: fixture.meeting.id)
        XCTAssertTrue(historyAfterDuplicate.isEmpty)
    }

    func testIdempotentAppendLinearUndoAndTombstonePreserveHistory() async throws {
        let fixture = try await makeFixture(segmentCount: 1)
        let source = fixture.segments[0]
        let first = event(
            101,
            fixture: fixture,
            targets: [source.id],
            kind: .replaceText(text: "First", language: "en"))
        let second = event(
            102,
            fixture: fixture,
            targets: [source.id],
            kind: .replaceText(text: "Second", language: "en"),
            supersedes: first.id)
        let restore = event(
            103,
            fixture: fixture,
            targets: [source.id],
            kind: .restore,
            supersedes: second.id)

        let persisted = try await fixture.store.appendTranscriptCorrection(first)
        let retry = try await fixture.store.appendTranscriptCorrection(first)
        XCTAssertEqual(retry, persisted)
        _ = try await fixture.store.appendTranscriptCorrection(second)
        _ = try await fixture.store.appendTranscriptCorrection(restore)

        let tombstone = try await fixture.store.tombstoneTranscriptCorrection(
            restore.id,
            meetingID: fixture.meeting.id,
            at: date(200))
        XCTAssertNotNil(tombstone.deletedAt)
        let tombstoneRetry = try await fixture.store.tombstoneTranscriptCorrection(
            restore.id,
            meetingID: fixture.meeting.id,
            at: date(201))
        XCTAssertEqual(tombstoneRetry, tombstone)

        let history = try await fixture.store.transcriptCorrectionHistory(
            for: fixture.meeting.id)
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.last, tombstone)
        let composition = try ComposeTranscript().execute(
            baseTranscriptRevision: fixture.meeting.transcriptRevision,
            baseMaterial: .refined,
            segments: fixture.segments,
            corrections: history)
        XCTAssertEqual(composition.composed.rows.map(\.text), [source.text])

        let resurrectingSuccessor = event(
            104,
            fixture: fixture,
            targets: [source.id],
            kind: .replaceText(text: "Resurrected", language: "en"),
            supersedes: restore.id)
        await assertInvalidCorrection {
            _ = try await fixture.store.appendTranscriptCorrection(resurrectingSuccessor)
        }

        let reusedIdentity = event(
            101,
            fixture: fixture,
            targets: [source.id],
            kind: .suppress)
        await assertInvalidCorrection {
            _ = try await fixture.store.appendTranscriptCorrection(reusedIdentity)
        }
        try await fixture.store.database.read { database in
            XCTAssertEqual(
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM transcriptCorrectionTarget"),
                3)
            XCTAssertEqual(
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM transcriptCorrectionPayload"),
                2)
        }
    }

    func testAppendRejectsStaleForeignOverlappingAndMalformedEventsAtomically() async throws {
        let fixture = try await makeFixture(segmentCount: 4)
        let first = event(
            101,
            fixture: fixture,
            targets: [fixture.segments[0].id],
            kind: .suppress)
        _ = try await fixture.store.appendTranscriptCorrection(first)

        await assertInvalidCorrection {
            _ = try await fixture.store.appendTranscriptCorrection(self.event(
                102,
                fixture: fixture,
                targets: [fixture.segments[0].id],
                kind: .changeSpeaker(fixture.secondSpeaker.id)))
        }
        await assertInvalidCorrection {
            _ = try await fixture.store.appendTranscriptCorrection(self.event(
                103,
                fixture: fixture,
                targets: [fixture.segments[1].id],
                kind: .suppress,
                revision: fixture.meeting.transcriptRevision - 1))
        }

        let foreignMeeting = Meeting(
            title: "Foreign",
            startedAt: date(1),
            transcriptRevision: fixture.meeting.transcriptRevision)
        let foreignSpeaker = Speaker(meetingID: foreignMeeting.id, label: "S9")
        try await fixture.store.save(foreignMeeting)
        try await fixture.store.save([foreignSpeaker])
        await assertInvalidCorrection {
            _ = try await fixture.store.appendTranscriptCorrection(self.event(
                104,
                fixture: fixture,
                targets: [fixture.segments[1].id],
                kind: .changeSpeaker(foreignSpeaker.id)))
        }
        await assertInvalidCorrection {
            _ = try await fixture.store.appendTranscriptCorrection(self.event(
                105,
                fixture: fixture,
                targets: [fixture.segments[2].id],
                kind: .split([
                    self.part(305, text: "Gap one", start: 6, end: 6.5),
                    self.part(306, text: "Gap two", start: 7, end: 8),
                ])))
        }
        await assertInvalidCorrection {
            _ = try await fixture.store.appendTranscriptCorrection(self.event(
                106,
                fixture: fixture,
                targets: [fixture.segments[3].id],
                kind: .replaceText(text: "Hola", language: "ES_CO")))
        }

        let successor = event(
            107,
            fixture: fixture,
            targets: [fixture.segments[0].id],
            kind: .restore,
            supersedes: first.id)
        _ = try await fixture.store.appendTranscriptCorrection(successor)
        await assertInvalidCorrection {
            _ = try await fixture.store.appendTranscriptCorrection(self.event(
                108,
                fixture: fixture,
                targets: [fixture.segments[0].id],
                kind: .restore,
                supersedes: first.id))
        }

        let history = try await fixture.store.transcriptCorrectionHistory(
            for: fixture.meeting.id)
        XCTAssertEqual(history.count, 2)
        try await fixture.store.database.read { database in
            XCTAssertEqual(
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM transcriptCorrection"),
                2)
            XCTAssertEqual(
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM transcriptCorrectionPart"),
                0)
            XCTAssertTrue(try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testStructuralTargetsMustBeMeetingLocalAcceptedAndExplicitlyAdjacent() async throws {
        let fixture = try await makeFixture(segmentCount: 4)

        await assertInvalidCorrection {
            _ = try await fixture.store.appendTranscriptCorrection(self.event(
                201,
                fixture: fixture,
                targets: [fixture.segments[0].id, fixture.segments[2].id],
                kind: .merge(replacementText: nil, language: "en")))
        }
        await assertInvalidCorrection {
            _ = try await fixture.store.appendTranscriptCorrection(self.event(
                202,
                fixture: fixture,
                targets: [fixture.segments[2].id, fixture.segments[1].id],
                kind: .merge(replacementText: nil, language: "en")))
        }

        let foreignMeeting = Meeting(
            title: "Foreign correction source",
            startedAt: date(1),
            transcriptRevision: fixture.meeting.transcriptRevision)
        let foreignSegment = TranscriptSegment(
            meetingID: foreignMeeting.id,
            channel: .system,
            text: "Foreign evidence",
            language: "en",
            startTime: 0,
            endTime: 2,
            confidence: 0.9,
            isFinal: true)
        try await fixture.store.save(foreignMeeting)
        try await fixture.store.save([foreignSegment])
        await assertInvalidCorrection {
            _ = try await fixture.store.appendTranscriptCorrection(self.event(
                203,
                fixture: fixture,
                targets: [foreignSegment.id],
                kind: .suppress))
        }

        let history = try await fixture.store.transcriptCorrectionHistory(
            for: fixture.meeting.id)
        XCTAssertTrue(history.isEmpty)
    }

    func testHistorySurvivesSourceRetirementButFailsOnMalformedPayload() async throws {
        let fixture = try await makeFixture(segmentCount: 2)
        let correction = event(
            101,
            fixture: fixture,
            targets: [fixture.segments[0].id],
            kind: .replaceText(text: "Corrected", language: "en"))
        _ = try await fixture.store.appendTranscriptCorrection(correction)

        let retirementDate = date(200)
        try await fixture.store.database.write { database in
            try database.execute(
                sql: "UPDATE segment SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [
                    retirementDate,
                    retirementDate,
                    fixture.segments[0].id.uuidString,
                ])
        }
        let history = try await fixture.store.transcriptCorrectionHistory(
            for: fixture.meeting.id)
        XCTAssertEqual(history, [correction])

        try await fixture.store.database.write { database in
            try database.execute(
                sql: "DELETE FROM transcriptCorrectionPayload WHERE correctionID = ?",
                arguments: [correction.id.uuidString])
        }
        await assertInvalidCorrection {
            _ = try await fixture.store.transcriptCorrectionHistory(for: fixture.meeting.id)
        }
        await assertInvalidCorrection {
            _ = try await fixture.store.transcriptCorrectionSyncEnvelope(
                for: fixture.meeting.id)
        }
    }

    func testSchemaEnforcesTypedShapeImmutabilityAndOneParentSyncGeneration() async throws {
        let fixture = try await makeFixture(segmentCount: 1)
        let correction = event(
            101,
            fixture: fixture,
            targets: [fixture.segments[0].id],
            kind: .suppress)
        let generationBefore = try await localSyncGeneration(fixture)
        _ = try await fixture.store.appendTranscriptCorrection(correction)
        let generationAfter = try await localSyncGeneration(fixture)
        XCTAssertEqual(generationAfter, generationBefore + 1)

        try await fixture.store.database.read { database in
            XCTAssertEqual(
                try Set(database.columns(in: "transcriptCorrectionTarget").map(\.name)),
                ["correctionID", "segmentID", "ordinal"])
            XCTAssertEqual(
                Set(try Row.fetchAll(
                    database,
                    sql: "PRAGMA foreign_key_list(transcriptCorrectionTarget)")
                    .map { $0["table"] as String }),
                ["transcriptCorrection"])
            XCTAssertEqual(
                try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM sqlite_master
                        WHERE type = 'trigger' AND name LIKE 'transcriptCorrection%sync%'
                        """),
                3)
            XCTAssertEqual(
                try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM sqlite_master
                        WHERE type = 'trigger' AND name LIKE '%Correction%immutable_bu'
                        """),
                4)
        }

        let invalidID = id(999)
        let invalidDate = date(999)
        let sourceDeviceID = sourceDeviceID
        try await fixture.store.database.write { database in
            XCTAssertThrowsError(try database.execute(
                sql: "UPDATE transcriptCorrection SET kind = 'restore' WHERE id = ?",
                arguments: [correction.id.uuidString]))
            XCTAssertThrowsError(try database.execute(
                sql: """
                    INSERT INTO transcriptCorrection (
                        id, meetingID, baseTranscriptRevision, kind, author,
                        sourceDeviceID, createdAt, updatedAt
                    ) VALUES (?, ?, ?, 'unknown', 'user', ?, ?, ?)
                    """,
                arguments: [
                    invalidID.uuidString,
                    fixture.meeting.id.rawValue.uuidString,
                    fixture.meeting.transcriptRevision,
                    sourceDeviceID.uuidString,
                    invalidDate,
                    invalidDate,
                ]))
        }
        let generationAfterRejectedMutations = try await localSyncGeneration(fixture)
        XCTAssertEqual(generationAfterRejectedMutations, generationAfter)
    }

    func testEnvelopeRejectsWrongMeetingUnknownVersionAndNoncanonicalOrder() async throws {
        let fixture = try await makeFixture(segmentCount: 2)
        let first = event(
            101,
            fixture: fixture,
            targets: [fixture.segments[0].id],
            kind: .suppress)
        let second = event(
            102,
            fixture: fixture,
            targets: [fixture.segments[1].id],
            kind: .suppress)
        let envelope = try TranscriptCorrectionSyncEnvelope(
            meetingID: fixture.meeting.id,
            events: [second, first])
        XCTAssertEqual(envelope.events, [first, second])

        XCTAssertThrowsError(try TranscriptCorrectionSyncEnvelope(
            meetingID: MeetingID(),
            events: [first]))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope))
                as? [String: Any])
        object["formatVersion"] = 99
        XCTAssertThrowsError(try JSONDecoder().decode(
            TranscriptCorrectionSyncEnvelope.self,
            from: JSONSerialization.data(withJSONObject: object)))

        object["formatVersion"] = TranscriptCorrectionSyncEnvelope.currentFormatVersion
        object["events"] = Array(
            try XCTUnwrap(object["events"] as? [[String: Any]]).reversed())
        XCTAssertThrowsError(try JSONDecoder().decode(
            TranscriptCorrectionSyncEnvelope.self,
            from: JSONSerialization.data(withJSONObject: object)))
    }

    func testStrictDecodeRejectsMalformedIdentityAndOrderedTargets() async throws {
        let fixture = try await makeFixture(segmentCount: 1)
        let meetingKey = fixture.meeting.id.rawValue.uuidString
        let targetKey = fixture.segments[0].id.uuidString
        let firstID = id(901).uuidString
        let secondID = id(902).uuidString
        let thirdID = id(903).uuidString
        let deviceKey = sourceDeviceID.uuidString
        let createdAt = date(901)

        try await fixture.store.database.write { database in
            try Self.insertRawSuppressCorrection(
                id: firstID,
                meetingKey: meetingKey,
                sourceDeviceKey: deviceKey,
                createdAt: createdAt,
                in: database)
            try database.execute(
                sql: """
                    INSERT INTO transcriptCorrectionTarget (
                        correctionID, segmentID, ordinal
                    ) VALUES (?, 'not-a-uuid', 0)
                    """,
                arguments: [firstID])
        }
        await assertStorageFailure {
            _ = try await fixture.store.transcriptCorrectionHistory(for: fixture.meeting.id)
        }

        try await fixture.store.database.write { database in
            try database.execute(
                sql: "DELETE FROM transcriptCorrection WHERE id = ?",
                arguments: [firstID])
            try Self.insertRawSuppressCorrection(
                id: secondID,
                meetingKey: meetingKey,
                sourceDeviceKey: deviceKey,
                createdAt: createdAt,
                in: database)
            try database.execute(
                sql: """
                    INSERT INTO transcriptCorrectionTarget (
                        correctionID, segmentID, ordinal
                    ) VALUES (?, ?, 1)
                    """,
                arguments: [secondID, targetKey])
        }
        await assertStorageFailure {
            _ = try await fixture.store.transcriptCorrectionHistory(for: fixture.meeting.id)
        }

        try await fixture.store.database.write { database in
            try database.execute(
                sql: "DELETE FROM transcriptCorrection WHERE id = ?",
                arguments: [secondID])
            try Self.insertRawSuppressCorrection(
                id: thirdID,
                meetingKey: meetingKey,
                sourceDeviceKey: String(repeating: "x", count: 36),
                createdAt: createdAt,
                in: database)
            try database.execute(
                sql: """
                    INSERT INTO transcriptCorrectionTarget (
                        correctionID, segmentID, ordinal
                    ) VALUES (?, ?, 0)
                    """,
                arguments: [thirdID, targetKey])
        }
        await assertStorageFailure {
            _ = try await fixture.store.transcriptCorrectionHistory(for: fixture.meeting.id)
        }
    }
}

private extension TranscriptCorrectionStorageTests {
    struct Fixture {
        let store: MeetingStore
        let meeting: Meeting
        let firstSpeaker: Speaker
        let secondSpeaker: Speaker
        let segments: [TranscriptSegment]
    }

    func makeFixture(segmentCount: Int) async throws -> Fixture {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Correction storage",
            startedAt: date(0),
            language: "en",
            transcriptRevision: 3)
        let firstSpeaker = Speaker(meetingID: meeting.id, label: "S1")
        let secondSpeaker = Speaker(meetingID: meeting.id, label: "S2")
        let segments = (0..<segmentCount).map { index in
            TranscriptSegment(
                id: id(index + 1),
                meetingID: meeting.id,
                speakerID: firstSpeaker.id,
                channel: .system,
                text: "Segment \(index + 1)",
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

    func event(
        _ value: Int,
        fixture: Fixture,
        targets: [UUID],
        kind: TranscriptCorrectionKind,
        supersedes: UUID? = nil,
        revision: Int? = nil
    ) -> TranscriptCorrectionEvent {
        TranscriptCorrectionEvent(
            id: id(value),
            meetingID: fixture.meeting.id,
            baseTranscriptRevision: revision ?? fixture.meeting.transcriptRevision,
            targetSegmentIDs: targets,
            kind: kind,
            sourceDeviceID: sourceDeviceID,
            createdAt: date(Double(value)),
            supersedesCorrectionID: supersedes)
    }

    func part(
        _ value: Int,
        text: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> TranscriptCorrectionPart {
        TranscriptCorrectionPart(
            id: id(value),
            text: text,
            speakerID: nil,
            language: "en",
            startTime: start,
            endTime: end)
    }

    func localSyncGeneration(_ fixture: Fixture) async throws -> Int {
        try await fixture.store.database.read { database in
            try XCTUnwrap(Int.fetchOne(
                database,
                sql: "SELECT localGeneration FROM meetingSyncState WHERE meetingID = ?",
                arguments: [fixture.meeting.id.rawValue.uuidString]))
        }
    }

    func assertInvalidCorrection(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected invalid transcript correction", file: file, line: line)
        } catch let error as StorageError {
            guard case .invalidTranscriptCorrection = error else {
                return XCTFail("unexpected storage error: \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    func assertStorageFailure(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected strict storage decoding to fail", file: file, line: line)
        } catch is StorageError {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    static func insertRawSuppressCorrection(
        id: String,
        meetingKey: String,
        sourceDeviceKey: String,
        createdAt: Date,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO transcriptCorrection (
                    id, meetingID, baseTranscriptRevision, kind, author,
                    sourceDeviceID, createdAt, updatedAt
                ) VALUES (?, ?, 3, 'suppress', 'user', ?, ?, ?)
                """,
            arguments: [id, meetingKey, sourceDeviceKey, createdAt, createdAt])
    }

    func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + offset)
    }

    func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
    }
}
