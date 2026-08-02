import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class CommitmentContinuityPolicyTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_785_600_000)

    func testProjectionRequiresOneConfirmAndStrictLifecycle() throws {
        let commitmentID = CommitmentID()
        let confirm = CommitmentEvent(
            commitmentID: commitmentID,
            kind: .confirm,
            occurredAt: baseDate)
        let complete = CommitmentEvent(
            commitmentID: commitmentID,
            kind: .complete,
            occurredAt: baseDate.addingTimeInterval(1))
        let duplicateComplete = CommitmentEvent(
            commitmentID: commitmentID,
            kind: .complete,
            occurredAt: baseDate.addingTimeInterval(2))

        XCTAssertThrowsError(try CommitmentContinuityPolicy.projectedCommitment(
            id: commitmentID,
            title: "Ship the rollout",
            events: [confirm, complete, duplicateComplete])) { error in
                XCTAssertEqual(
                    error as? CommitmentContinuityValidationError,
                    .invalidLifecycle(duplicateComplete.id))
            }

        let secondConfirm = CommitmentEvent(
            commitmentID: commitmentID,
            kind: .confirm,
            occurredAt: baseDate.addingTimeInterval(1))
        XCTAssertThrowsError(try CommitmentContinuityPolicy.projectedCommitment(
            id: commitmentID,
            title: "Ship the rollout",
            events: [confirm, secondConfirm]))
    }

    func testEnvelopeCanonicalizesRowsAndRoundTrips() throws {
        let commitmentID = CommitmentID()
        let earlySource = CommitmentSource(
            commitmentID: commitmentID,
            kind: .manual,
            meetingID: nil,
            firstSeenAt: baseDate)
        let lateSource = CommitmentSource(
            commitmentID: commitmentID,
            kind: .manual,
            meetingID: nil,
            firstSeenAt: baseDate.addingTimeInterval(1))
        let confirm = CommitmentEvent(
            commitmentID: commitmentID,
            kind: .confirm,
            occurredAt: baseDate)
        let complete = CommitmentEvent(
            commitmentID: commitmentID,
            kind: .complete,
            occurredAt: baseDate.addingTimeInterval(2))
        let commitment = try CommitmentContinuityPolicy.projectedCommitment(
            id: commitmentID,
            title: "  Ship the rollout  ",
            events: [complete, confirm])

        let envelope = try CommitmentContinuityEnvelope(
            commitment: commitment,
            sources: [lateSource, earlySource],
            events: [complete, confirm])
        XCTAssertEqual(envelope.commitment.title, "Ship the rollout")
        XCTAssertEqual(envelope.sources.map(\.id), [earlySource.id, lateSource.id])
        XCTAssertEqual(envelope.events.map(\.id), [confirm.id, complete.id])

        let data = try JSONEncoder().encode(envelope)
        XCTAssertEqual(try JSONDecoder().decode(
            CommitmentContinuityEnvelope.self,
            from: data), envelope)
    }

    func testDecoderRejectsFutureVersionAndNoncanonicalHistory() throws {
        let commitmentID = CommitmentID()
        let source = CommitmentSource(
            commitmentID: commitmentID,
            kind: .manual,
            meetingID: nil,
            firstSeenAt: baseDate)
        let confirm = CommitmentEvent(
            commitmentID: commitmentID,
            kind: .confirm,
            occurredAt: baseDate)
        let complete = CommitmentEvent(
            commitmentID: commitmentID,
            kind: .complete,
            occurredAt: baseDate.addingTimeInterval(1))
        let commitment = try CommitmentContinuityPolicy.projectedCommitment(
            id: commitmentID,
            title: "Ship",
            events: [confirm, complete])
        let envelope = try CommitmentContinuityEnvelope(
            commitment: commitment,
            sources: [source],
            events: [confirm, complete])
        let data = try JSONEncoder().encode(envelope)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        object["formatVersion"] = 99
        let futureData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(
            CommitmentContinuityEnvelope.self,
            from: futureData))

        object["formatVersion"] = CommitmentContinuityEnvelope.currentFormatVersion
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        object["events"] = Array(events.reversed())
        let unorderedData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(
            CommitmentContinuityEnvelope.self,
            from: unorderedData))
    }
}

final class CommitmentContinuityStorageTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_785_600_000)

    func testGeneratedConfirmationRequiresCurrentDirectEvidenceAndExactPerson() async throws {
        let fixture = try await generatedFixture()
        let confirmation = CommitmentConfirmation(
            title: "Prepare the rollout",
            canonicalPersonID: fixture.personID,
            dueAt: baseDate.addingTimeInterval(86_400),
            origin: .generatedActionItem(fixture.actionItemID))

        let envelope = try await fixture.store.confirmCommitment(
            confirmation,
            at: baseDate)

        XCTAssertEqual(envelope.commitment.status, .confirmed)
        XCTAssertEqual(envelope.commitment.canonicalPersonID, fixture.personID)
        XCTAssertEqual(envelope.sources.first?.kind, .generatedActionItem)
        XCTAssertEqual(envelope.sources.first?.meetingID, fixture.meeting.id)
        XCTAssertEqual(envelope.sources.first?.actionItemID, fixture.actionItemID)
        XCTAssertEqual(envelope.sources.first?.transcriptRevision, 0)
        XCTAssertEqual(
            envelope.sources.first?.evidence.map(\.segmentID),
            [fixture.evidenceSegmentID])
        XCTAssertEqual(envelope.events.map(\.kind), [.confirm])
    }

    func testUnknownPersonFailsAtomicallyWithoutAliasInference() async throws {
        let fixture = try await generatedFixture()
        let unknownPersonID = PersonID()

        await assertThrows {
            _ = try await fixture.store.confirmCommitment(
                CommitmentConfirmation(
                    title: "Ana will prepare the rollout",
                    canonicalPersonID: unknownPersonID,
                    origin: .generatedActionItem(fixture.actionItemID)),
                at: self.baseDate)
        }
        let counts = try await continuityCounts(in: fixture.store)
        XCTAssertEqual(counts, [0, 0, 0, 0])

        let unassigned = try await fixture.store.confirmCommitment(
            CommitmentConfirmation(
                title: "Ana will prepare the rollout",
                origin: .generatedActionItem(fixture.actionItemID)),
            at: baseDate)
        XCTAssertNil(
            unassigned.commitment.canonicalPersonID,
            "a matching alias in the title must never assign canonical identity")
    }

    func testMissingOrStaleGeneratedEvidenceLeavesNoContinuityRows() async throws {
        let missing = try await generatedFixture(includeEvidence: false)
        await assertThrows {
            _ = try await missing.store.confirmCommitment(
                CommitmentConfirmation(
                    title: "Prepare the rollout",
                    origin: .generatedActionItem(missing.actionItemID)),
                at: self.baseDate)
        }
        let missingCounts = try await continuityCounts(in: missing.store)
        XCTAssertEqual(missingCounts, [0, 0, 0, 0])

        let stale = try await generatedFixture()
        var changedMeeting = stale.meeting
        changedMeeting.transcriptRevision = 1
        try await stale.store.save(changedMeeting)
        await assertThrows {
            _ = try await stale.store.confirmCommitment(
                CommitmentConfirmation(
                    title: "Prepare the rollout",
                    origin: .generatedActionItem(stale.actionItemID)),
                at: self.baseDate)
        }
        let staleCounts = try await continuityCounts(in: stale.store)
        XCTAssertEqual(staleCounts, [0, 0, 0, 0])
    }

    func testManualAndUserNoteOriginsRemainExplicitUserTruth() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Planning", startedAt: baseDate)
        let note = ContextItem(
            meetingID: meeting.id,
            kind: .note,
            content: "I will send the report",
            timestamp: 12)
        try await store.save(meeting)
        try await store.save([note])

        let noteEnvelope = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Send the report",
                origin: .userNote(note.id)),
            at: baseDate)
        let manualEnvelope = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Review the report",
                origin: .manual(meetingID: nil)),
            at: baseDate.addingTimeInterval(1))

        XCTAssertEqual(noteEnvelope.sources.first?.kind, .userNote)
        XCTAssertEqual(noteEnvelope.sources.first?.contextItemID, note.id)
        XCTAssertEqual(noteEnvelope.sources.first?.meetingID, meeting.id)
        XCTAssertTrue(noteEnvelope.sources.first?.evidence.isEmpty == true)
        XCTAssertEqual(manualEnvelope.sources.first?.kind, .manual)
        XCTAssertNil(manualEnvelope.sources.first?.meetingID)
        XCTAssertTrue(manualEnvelope.sources.first?.evidence.isEmpty == true)
    }

    func testLifecycleProjectsFromAppendOnlyHistory() async throws {
        let fixture = try await generatedFixture()
        let initial = try await fixture.store.confirmCommitment(
            CommitmentConfirmation(
                title: "Prepare the rollout",
                canonicalPersonID: fixture.personID,
                origin: .generatedActionItem(fixture.actionItemID)),
            at: baseDate)
        let commitmentID = initial.commitment.id

        _ = try await fixture.store.applyCommitmentTransition(
            .complete, to: commitmentID, at: baseDate.addingTimeInterval(1))
        _ = try await fixture.store.applyCommitmentTransition(
            .reopen, to: commitmentID, at: baseDate.addingTimeInterval(2))
        let dueAt = baseDate.addingTimeInterval(172_800)
        _ = try await fixture.store.applyCommitmentTransition(
            .reschedule(dueAt), to: commitmentID, at: baseDate.addingTimeInterval(3))
        _ = try await fixture.store.applyCommitmentTransition(
            .reassign(nil), to: commitmentID, at: baseDate.addingTimeInterval(4))
        let dismissed = try await fixture.store.applyCommitmentTransition(
            .dismiss,
            to: commitmentID,
            sourceMeetingID: fixture.meeting.id,
            at: baseDate.addingTimeInterval(5))

        XCTAssertEqual(dismissed.commitment.status, .dismissed)
        XCTAssertNil(dismissed.commitment.canonicalPersonID)
        XCTAssertEqual(dismissed.commitment.dueAt, dueAt)
        XCTAssertEqual(
            dismissed.events.map(\.kind),
            [.confirm, .complete, .reopen, .reschedule, .reassign, .dismiss])
        XCTAssertEqual(dismissed.events.last?.sourceMeetingID, fixture.meeting.id)
        let reloaded = try await fixture.store.commitmentContinuityEnvelope(
            for: commitmentID)
        XCTAssertEqual(reloaded, dismissed)
    }

    func testInvalidLifecycleRollsBackEventAndProjection() async throws {
        let store = try MeetingStore.inMemory()
        let initial = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Ship",
                origin: .manual(meetingID: nil)),
            at: baseDate)
        let completed = try await store.applyCommitmentTransition(
            .complete,
            to: initial.commitment.id,
            at: baseDate.addingTimeInterval(1))

        await assertThrows {
            _ = try await store.applyCommitmentTransition(
                .reschedule(self.baseDate.addingTimeInterval(500)),
                to: initial.commitment.id,
                at: self.baseDate.addingTimeInterval(2))
        }
        let after = try await store.commitmentContinuityEnvelope(
            for: initial.commitment.id)
        XCTAssertEqual(after, completed)
        XCTAssertEqual(after.events.count, 2)
    }

    func testPortableReplayIsIdempotentAndFailsClosedOnConflict() async throws {
        let source = try MeetingStore.inMemory()
        let destination = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Portable source", startedAt: baseDate)
        try await source.save(meeting)
        try await destination.save(meeting)
        let envelope = try await source.confirmCommitment(
            CommitmentConfirmation(
                title: "Send the report",
                origin: .manual(meetingID: meeting.id)),
            at: baseDate)

        let imported = try await destination.applyCommitmentContinuityEnvelope(envelope)
        XCTAssertEqual(imported, envelope)
        let replayed = try await destination.applyCommitmentContinuityEnvelope(envelope)
        XCTAssertEqual(replayed, envelope, "an exact replay must be a no-op")
        let initialCounts = try await continuityCounts(in: destination)
        XCTAssertEqual(initialCounts, [1, 1, 0, 1])

        let conflictingCommitment = Commitment(
            id: envelope.commitment.id,
            title: "A different title",
            status: envelope.commitment.status,
            canonicalPersonID: envelope.commitment.canonicalPersonID,
            dueAt: envelope.commitment.dueAt,
            createdAt: envelope.commitment.createdAt,
            updatedAt: envelope.commitment.updatedAt)
        let conflict = try CommitmentContinuityEnvelope(
            commitment: conflictingCommitment,
            sources: envelope.sources,
            events: envelope.events)
        await assertThrows {
            _ = try await destination.applyCommitmentContinuityEnvelope(conflict)
        }
        let conflictCounts = try await continuityCounts(in: destination)
        XCTAssertEqual(conflictCounts, [1, 1, 0, 1])
    }

    func testPortableReplayRequiresExactLocalSourceIdentity() async throws {
        let source = try MeetingStore.inMemory()
        let destination = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Portable source", startedAt: baseDate)
        try await source.save(meeting)
        let envelope = try await source.confirmCommitment(
            CommitmentConfirmation(
                title: "Send the report",
                origin: .manual(meetingID: meeting.id)),
            at: baseDate)

        await assertThrows {
            _ = try await destination.applyCommitmentContinuityEnvelope(envelope)
        }
        let counts = try await continuityCounts(in: destination)
        XCTAssertEqual(counts, [0, 0, 0, 0])
    }

    func testHistoryRowsAndCommitmentIdentityAreDatabaseImmutable() async throws {
        let fixture = try await generatedFixture()
        let envelope = try await fixture.store.confirmCommitment(
            CommitmentConfirmation(
                title: "Prepare the rollout",
                origin: .generatedActionItem(fixture.actionItemID)),
            at: baseDate)
        let sourceID = try XCTUnwrap(envelope.sources.first?.id)
        let eventID = try XCTUnwrap(envelope.events.first?.id)
        let changedDate = baseDate.addingTimeInterval(1)

        try await fixture.store.database.write { database in
            XCTAssertThrowsError(try database.execute(
                sql: "UPDATE commitment SET title = 'Changed' WHERE id = ?",
                arguments: [envelope.commitment.id.rawValue.uuidString]))
            XCTAssertThrowsError(try database.execute(
                sql: "UPDATE commitmentSource SET firstSeenAt = ? WHERE id = ?",
                arguments: [changedDate, sourceID.rawValue.uuidString]))
            XCTAssertThrowsError(try database.execute(
                sql: "UPDATE commitmentEvidenceSegment SET role = 'deadline' WHERE sourceID = ?",
                arguments: [sourceID.rawValue.uuidString]))
            XCTAssertThrowsError(try database.execute(
                sql: "UPDATE commitmentEvent SET occurredAt = ? WHERE id = ?",
                arguments: [changedDate, eventID.rawValue.uuidString]))
        }
        let reloaded = try await fixture.store.commitmentContinuityEnvelope(
            for: envelope.commitment.id)
        XCTAssertEqual(reloaded, envelope)
    }

    func testConfirmedSourceHistorySurvivesMeetingPurge() async throws {
        let fixture = try await generatedFixture()
        let envelope = try await fixture.store.confirmCommitment(
            CommitmentConfirmation(
                title: "Prepare the rollout",
                canonicalPersonID: fixture.personID,
                origin: .generatedActionItem(fixture.actionItemID)),
            at: baseDate)

        try await fixture.store.delete(fixture.meeting.id)
        try await fixture.store.purge(fixture.meeting.id)

        let retained = try await fixture.store.commitmentContinuityEnvelope(
            for: envelope.commitment.id)
        XCTAssertEqual(retained, envelope)
        let foreignKeyFailures = try fixture.store.database.read { database in
            try Row.fetchAll(database, sql: "PRAGMA foreign_key_check")
        }
        XCTAssertTrue(foreignKeyFailures.isEmpty)
    }

    private func generatedFixture(
        includeEvidence: Bool = true
    ) async throws -> GeneratedFixture {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Planning", startedAt: baseDate)
        let participant = Speaker(meetingID: meeting.id, label: "S1", displayName: "Ana")
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: participant.id,
            channel: .system,
            text: "I will prepare the rollout by Friday.",
            startTime: 1,
            endTime: 4,
            isFinal: true)
        try await store.save(meeting)
        try await store.save([participant])
        try await store.save([segment])
        let person = try await store.createPersonAndLink(
            speakerID: participant.id,
            preferredName: "Ana",
            source: .manualName)
        let actionItem = ActionItem(
            text: "Prepare the rollout",
            ownerSpeakerID: participant.id)
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "Ana will prepare the rollout by Friday.",
            actionItems: [actionItem],
            actionItemEvidence: includeEvidence
                ? [SummaryActionItemEvidence(
                    actionItemID: actionItem.id,
                    evidenceSegmentIDs: [segment.id])]
                : []))
        return GeneratedFixture(
            store: store,
            meeting: meeting,
            actionItemID: actionItem.id,
            evidenceSegmentID: segment.id,
            personID: person.person.id)
    }
}

private struct GeneratedFixture {
    let store: MeetingStore
    let meeting: Meeting
    let actionItemID: UUID
    let evidenceSegmentID: UUID
    let personID: PersonID
}

private func continuityCounts(in store: MeetingStore) async throws -> [Int] {
    try await store.database.read { database in
        try [
            "commitment", "commitmentSource", "commitmentEvidenceSegment",
            "commitmentEvent",
        ].map { table in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
        }
    }
}

private func assertThrows(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
