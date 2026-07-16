import Foundation
import PortavozCore
import XCTest

@testable import StorageKit

final class LibraryObservationTests: XCTestCase {
    func testScopedObservationsTrackOnlyTheirQueryInputsThroughLifecycle() async throws {
        let store = try MeetingStore.inMemory()
        var meetingRows = store.observeLibraryMeetings().makeAsyncIterator()
        var openItems = store.observeLibraryOpenItems().makeAsyncIterator()
        var trash = store.observeLibraryTrash().makeAsyncIterator()

        let initialRows = try await nextMeetingRows(&meetingRows)
        let initialOpenItems = try await nextOpenItems(&openItems)
        let initialTrash = try await nextTrash(&trash)
        XCTAssertTrue(initialRows.rows.isEmpty)
        XCTAssertTrue(initialOpenItems.isEmpty)
        XCTAssertTrue(initialTrash.isEmpty)

        let meeting = Meeting(title: "Planning", startedAt: Date())
        try await store.save(meeting)
        let afterMeeting = try await nextMeetingRows(&meetingRows) {
            $0.rows.map(\.meeting.id) == [meeting.id]
        }
        XCTAssertTrue(afterMeeting.rows.first?.voiceMix.isEmpty == true)

        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        try await store.save([me])
        try await store.save([
            TranscriptSegment(
                meetingID: meeting.id,
                speakerID: me.id,
                channel: .microphone,
                text: "Revisemos el presupuesto",
                startTime: 0,
                endTime: 4,
                isFinal: true)
        ])
        let afterTranscript = try await nextMeetingRows(&meetingRows) {
            $0.rows.first?.voiceMix.count == 1
        }
        XCTAssertEqual(afterTranscript.rows.first?.voiceMix.first?.fraction, 1)

        let action = ActionItem(text: "Enviar propuesta")
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "es",
            markdown: "# Resumen",
            actionItems: [action]))
        let afterSummary = try await nextOpenItems(&openItems) {
            $0.map(\.item.id) == [action.id]
        }
        XCTAssertEqual(afterSummary.first?.meetingTitle, meeting.title)

        try await store.setActionItem(action.id, done: true)
        let afterAction = try await nextOpenItems(&openItems) { $0.isEmpty }
        XCTAssertTrue(afterAction.isEmpty)

        try await store.delete(meeting.id)
        let afterDelete = try await nextMeetingRows(&meetingRows) { $0.rows.isEmpty }
        XCTAssertTrue(afterDelete.rows.isEmpty)
        let trashAfterDelete = try await nextTrash(&trash) {
            $0.map(\.meeting.id) == [meeting.id]
        }
        XCTAssertEqual(trashAfterDelete.first?.meeting.id, meeting.id)

        try await store.restore(meeting.id)
        let afterRestore = try await nextMeetingRows(&meetingRows) {
            $0.rows.map(\.meeting.id) == [meeting.id]
        }
        XCTAssertEqual(afterRestore.rows.first?.voiceMix.count, 1)
        let trashAfterRestore = try await nextTrash(&trash) { $0.isEmpty }
        XCTAssertTrue(trashAfterRestore.isEmpty)
    }

    func testSearchObservationRefreshesFromBaseSegmentAndMeetingWrites() async throws {
        let store = try MeetingStore.inMemory()
        var iterator = store.observeLibrarySearch("presupuesto").makeAsyncIterator()

        let initial = try await nextSearch(&iterator)
        XCTAssertTrue(initial.isEmpty)

        var meeting = Meeting(title: "Planning", startedAt: Date())
        try await store.save(meeting)
        var segment = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "El presupuesto queda aprobado",
            startTime: 3,
            endTime: 5,
            isFinal: true)
        try await store.save([segment])

        let inserted = try await nextSearch(&iterator) { $0.count == 1 }
        XCTAssertEqual(inserted.first?.meetingID, meeting.id)
        XCTAssertEqual(inserted.first?.segmentID, segment.id)

        meeting.title = "Budget review"
        try await store.save(meeting)
        let renamed = try await nextSearch(&iterator) {
            $0.first?.meetingTitle == "Budget review"
        }
        XCTAssertEqual(renamed.first?.segmentID, segment.id)

        segment.text = "El alcance queda aprobado"
        try await store.save([segment])
        let removed = try await nextSearch(&iterator) { $0.isEmpty }
        XCTAssertTrue(removed.isEmpty)
    }

    func testCorruptMeetingRowsDoNotStopIndependentLibraryQueries() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Corrupt", startedAt: Date())
        try await store.save(meeting)
        try await store.database.write { database in
            try database.execute(
                sql: "UPDATE meeting SET id = ? WHERE id = ?",
                arguments: ["corrupt-meeting-id", meeting.id.rawValue.uuidString])
        }
        var meetingRows = store.observeLibraryMeetings().makeAsyncIterator()
        var openItems = store.observeLibraryOpenItems().makeAsyncIterator()
        var trash = store.observeLibraryTrash().makeAsyncIterator()

        do {
            _ = try await meetingRows.next()
            XCTFail("corrupt meeting identity must fail its scoped projection")
        } catch {
            guard case StorageError.invalidPersistedUUID(
                table: "meeting", column: "id", value: "corrupt-meeting-id") = error
            else { return XCTFail("wrong error: \(error)") }
        }

        let readableOpenItems = try await nextOpenItems(&openItems)
        let readableTrash = try await nextTrash(&trash)
        XCTAssertTrue(readableOpenItems.isEmpty)
        XCTAssertTrue(readableTrash.isEmpty)
    }
}

private func nextMeetingRows(
    _ iterator: inout AsyncThrowingStream<MeetingStore.LibraryMeetingRows, Error>.Iterator,
    until predicate: (MeetingStore.LibraryMeetingRows) -> Bool = { _ in true }
) async throws -> MeetingStore.LibraryMeetingRows {
    for _ in 0..<12 {
        let candidate = try await iterator.next()
        let rows = try XCTUnwrap(candidate)
        if predicate(rows) { return rows }
    }
    throw LibraryObservationTestError.expectedValue
}

private func nextOpenItems(
    _ iterator: inout AsyncThrowingStream<[MeetingStore.OpenActionItem], Error>.Iterator,
    until predicate: ([MeetingStore.OpenActionItem]) -> Bool = { _ in true }
) async throws -> [MeetingStore.OpenActionItem] {
    for _ in 0..<12 {
        let candidate = try await iterator.next()
        let items = try XCTUnwrap(candidate)
        if predicate(items) { return items }
    }
    throw LibraryObservationTestError.expectedValue
}

private func nextTrash(
    _ iterator: inout AsyncThrowingStream<[MeetingStore.DeletedMeeting], Error>.Iterator,
    until predicate: ([MeetingStore.DeletedMeeting]) -> Bool = { _ in true }
) async throws -> [MeetingStore.DeletedMeeting] {
    for _ in 0..<12 {
        let candidate = try await iterator.next()
        let items = try XCTUnwrap(candidate)
        if predicate(items) { return items }
    }
    throw LibraryObservationTestError.expectedValue
}

private func nextSearch(
    _ iterator: inout AsyncThrowingStream<[SearchHit], Error>.Iterator,
    until predicate: ([SearchHit]) -> Bool = { _ in true }
) async throws -> [SearchHit] {
    for _ in 0..<12 {
        let candidate = try await iterator.next()
        let hits = try XCTUnwrap(candidate)
        if predicate(hits) { return hits }
    }
    throw LibraryObservationTestError.expectedValue
}

private enum LibraryObservationTestError: Error {
    case expectedValue
}
