import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class DictationMeetingNoteStoreTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testAddingCopiesTheTextIntoTheMeetingNotesAtTheMomentItWasDictated() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = try await finishedMeeting(store)
        let during = try await saved(store, "Revisar el presupuesto.", at: start.addingTimeInterval(120))
        let after = try await saved(store, "Send the report.", at: start.addingTimeInterval(7_200))

        let first = try await store.addDictationToMeeting(during.id, meetingID: meeting.id, at: start)
        let second = try await store.addDictationToMeeting(after.id, meetingID: meeting.id, at: start)
        let notes = try await store.contextItems(for: meeting.id).filter { $0.kind == .note }
        let links = try await store.dictationMeetingLinks(for: [during.id, after.id])
        let syncChanged = try await store.database.read {
            try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM meetingSyncState WHERE meetingID = ?)",
                              arguments: [meeting.id.rawValue.uuidString])
        }

        guard case .added(_, false) = first, case .added = second else { return XCTFail("both must be added") }
        XCTAssertEqual(notes.map(\.content), ["Revisar el presupuesto.", "Send the report."])
        XCTAssertEqual(notes.map(\.timestamp), [120, 1_800], "a later dictation sits at the meeting's end")
        XCTAssertEqual(links[during.id]?.map(\.title), ["Weekly"])
        XCTAssertEqual(syncChanged, true, "the note follows the meeting like any other note")
    }

    func testTheSameDictationIsAddedOnceUntilItsNoteIsRemoved() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = try await finishedMeeting(store)
        let dictation = try await saved(store, "Una vez.", at: start)

        let first = try await store.addDictationToMeeting(dictation.id, meetingID: meeting.id, at: start)
        let again = try await store.addDictationToMeeting(dictation.id, meetingID: meeting.id, at: start)
        guard case .added(let noteID, _) = first else { return XCTFail("must be added") }
        try await store.deleteContextItem(noteID)
        let linksAfterRemoval = try await store.dictationMeetingLinks(for: [dictation.id])
        let readded = try await store.addDictationToMeeting(dictation.id, meetingID: meeting.id, at: start)

        XCTAssertEqual(again, .alreadyAdded)
        XCTAssertEqual(linksAfterRemoval, [:], "a removed note no longer counts as added")
        guard case .added(let newNote, _) = readded else { return XCTFail("a removed copy can be added again") }
        XCTAssertNotEqual(newNote, noteID)
    }

    func testOnlyFinishedLiveMeetingsAndSavedDictationsQualify() async throws {
        let store = try MeetingStore.inMemory()
        let recording = Meeting(title: "Live", startedAt: start, lifecycleState: .recording)
        try await store.save(recording)
        let deleted = try await finishedMeeting(store, title: "Gone")
        let deletedAt = start
        try await store.database.write {
            try $0.execute(sql: "UPDATE meeting SET deletedAt = ? WHERE id = ?",
                           arguments: [deletedAt, deleted.id.rawValue.uuidString])
        }
        let dictation = try await saved(store, "Texto.", at: start)

        let toRecording = try await store.addDictationToMeeting(dictation.id, meetingID: recording.id, at: start)
        let toDeleted = try await store.addDictationToMeeting(dictation.id, meetingID: deleted.id, at: start)
        let toUnknown = try await store.addDictationToMeeting(dictation.id, meetingID: MeetingID(), at: start)
        let unknownDictation = try await store.addDictationToMeeting(
            DictationRecordID(), meetingID: deleted.id, at: start)
        let choices = try await store.meetingsForDictation(createdAt: start, limit: 20)

        XCTAssertEqual([toRecording, toDeleted, toUnknown], Array(repeating: .meetingUnavailable, count: 3))
        XCTAssertEqual(unknownDictation, .dictationMissing)
        XCTAssertEqual(choices, [], "recording and deleted meetings are not offered")
    }

    func testChoicesPutTheMeetingRecordedDuringTheDictationFirst() async throws {
        let store = try MeetingStore.inMemory()
        let earlier = try await finishedMeeting(store, title: "Earlier", startedAt: start.addingTimeInterval(-7_200))
        let later = try await finishedMeeting(store, title: "Later", startedAt: start.addingTimeInterval(7_200))

        let choices = try await store.meetingsForDictation(createdAt: earlier.startedAt.addingTimeInterval(60), limit: 20)

        XCTAssertEqual(choices.map(\.title), ["Earlier", "Later"])
        XCTAssertEqual(choices.map(\.containsDictation), [true, false])
        XCTAssertEqual(choices.last?.id, later.id)
    }

    func testDeletingTheDictationKeepsTheNoteAndTidiedNotesAreReported() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = try await finishedMeeting(store)
        let createdAt = start
        try await store.database.write {
            try $0.execute(
                sql: """
                    INSERT INTO enhancedNote (id, meetingID, markdown, language, inputFingerprint, createdAt, updatedAt)
                    VALUES (?, ?, '# Notes', 'es', 'fingerprint', ?, ?)
                    """,
                arguments: [UUID().uuidString, meeting.id.rawValue.uuidString, createdAt, createdAt])
        }
        let dictation = try await saved(store, "Se queda.", at: start)

        let outcome = try await store.addDictationToMeeting(dictation.id, meetingID: meeting.id, at: start)
        _ = try await store.deleteDictationRecord(dictation.id)
        let notes = try await store.contextItems(for: meeting.id).filter { $0.kind == .note }
        let orphanLinks = try await store.database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM dictationMeetingNote") ?? -1
        }

        guard case .added(_, true) = outcome else { return XCTFail("tidied notes must be reported") }
        XCTAssertEqual(notes.map(\.content), ["Se queda."], "the note now belongs to the meeting")
        XCTAssertEqual(orphanLinks, 0)
    }

    private func finishedMeeting(
        _ store: MeetingStore, title: String = "Weekly", startedAt: Date? = nil
    ) async throws -> Meeting {
        let begin = startedAt ?? start
        let meeting = Meeting(title: title, startedAt: begin, endedAt: begin.addingTimeInterval(1_800))
        try await store.save(meeting)
        return meeting
    }

    private func saved(_ store: MeetingStore, _ text: String, at createdAt: Date) async throws -> DictationRecord {
        let policy = try await store.setDictationHistoryPolicy(
            isEnabled: true, keepsOriginal: false, retentionDays: 90, at: createdAt)
        let record = DictationRecord(
            id: DictationRecordID(), createdAt: createdAt, duration: 2, text: text, originalText: nil,
            mode: .literal, language: nil, engine: "parakeet", applicationName: "Notes",
            applicationBundleID: nil, delivery: .verified)
        _ = try await store.recordDictation(record, admittedGeneration: policy.generation, at: createdAt)
        return record
    }
}
