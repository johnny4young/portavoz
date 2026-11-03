import Foundation
import PortavozCore
import XCTest

@testable import StorageKit

final class LibraryObservationTests: XCTestCase {
    /// The semantic backfill writes `embedding`/`embeddingFingerprint` on
    /// `segment` in batches. Tracking the whole table made every batch commit
    /// re-fetch the entire library and recompute every voice mix — the more of
    /// the library was being indexed, the more often it happened.
    func testIndexingEmbeddingsDoesNotRefireTheLibraryOrSearch() async throws {
        let store = try MeetingStore.inMemory()

        try await store.database.read { database in
            let library = try MeetingStore.librarySegmentRegion
                .databaseRegion(database)
            let search = try MeetingStore.searchSegmentRegion
                .databaseRegion(database)
            let correctedSearch = try MeetingStore.searchCorrectedTextRegion
                .databaseRegion(database)
            let structuralSearch = try MeetingStore.searchStructuralTextRegion
                .databaseRegion(database)

            for region in [library, search] {
                XCTAssertFalse(
                    region.isModified(byEventsOfKind: .update(
                        tableName: "segment",
                        columnNames: ["embedding", "embeddingFingerprint"])),
                    "indexing is not a library change")
            }

            // Everything either projection reads still re-fires it.
            XCTAssertTrue(library.isModified(byEventsOfKind: .update(
                tableName: "segment", columnNames: ["speakerID"])))
            XCTAssertTrue(library.isModified(byEventsOfKind: .update(
                tableName: "segment", columnNames: ["deletedAt"])))
            XCTAssertTrue(search.isModified(byEventsOfKind: .update(
                tableName: "segment", columnNames: ["text"])))
            XCTAssertTrue(search.isModified(byEventsOfKind: .update(
                tableName: "segment", columnNames: ["deletedAt"])))
            // A new or removed row is a change to every column.
            XCTAssertTrue(library.isModified(
                byEventsOfKind: .insert(tableName: "segment")))
            XCTAssertTrue(search.isModified(
                byEventsOfKind: .delete(tableName: "segment")))
            XCTAssertFalse(correctedSearch.isModified(byEventsOfKind: .update(
                tableName: "segmentCorrectedText",
                columnNames: ["embedding", "embeddingFingerprint"])))
            XCTAssertTrue(correctedSearch.isModified(byEventsOfKind: .update(
                tableName: "segmentCorrectedText", columnNames: ["text"])))
            XCTAssertFalse(structuralSearch.isModified(byEventsOfKind: .update(
                tableName: "transcriptStructuralSearchRow",
                columnNames: ["embedding", "embeddingFingerprint"])))
            XCTAssertTrue(structuralSearch.isModified(byEventsOfKind: .update(
                tableName: "transcriptStructuralSearchRow", columnNames: ["text"])))
        }
    }

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

    func testOpenItemsClampNonpositiveLimitsInsteadOfStreamingEverything() async throws {
        // SQLite treats a negative LIMIT as "no limit": without the clamp a
        // nonpositive caller value would stream every open action item.
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Planning", startedAt: Date())
        try await store.save(meeting)
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "es",
            markdown: "# Resumen",
            actionItems: [ActionItem(text: "Enviar propuesta")]))

        var zero = store.observeLibraryOpenItems(limit: 0).makeAsyncIterator()
        var negative = store.observeLibraryOpenItems(limit: -5).makeAsyncIterator()
        let zeroItems = try await nextOpenItems(&zero)
        let negativeItems = try await nextOpenItems(&negative)

        XCTAssertTrue(zeroItems.isEmpty)
        XCTAssertTrue(negativeItems.isEmpty)
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

    func testSearchObservationRefreshesWhenStructuralProjectionChanges() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Planning", startedAt: Date())
        let speaker = Speaker(meetingID: meeting.id, label: "S1")
        let segments = [
            TranscriptSegment(
                meetingID: meeting.id,
                speakerID: speaker.id,
                channel: .system,
                text: "alpha accepted",
                startTime: 0,
                endTime: 2,
                isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id,
                speakerID: speaker.id,
                channel: .system,
                text: "beta accepted",
                startTime: 2,
                endTime: 4,
                isFinal: true)
        ]
        try await store.save(meeting)
        try await store.save([speaker])
        try await store.save(segments)
        var iterator = store.observeLibrarySearch("merged").makeAsyncIterator()
        let initial = try await nextSearch(&iterator)
        XCTAssertTrue(initial.isEmpty)

        let merge = TranscriptCorrectionEvent(
            meetingID: meeting.id,
            baseTranscriptRevision: meeting.transcriptRevision,
            targetSegmentIDs: segments.map(\.id),
            kind: .merge(
                replacementText: "merged structural result",
                language: "en"),
            sourceDeviceID: UUID(),
            createdAt: Date())
        _ = try await store.appendTranscriptCorrection(merge)

        let updated = try await nextSearch(&iterator) { $0.count == 1 }
        XCTAssertEqual(updated.map(\.resultID), [merge.id])
        XCTAssertEqual(updated.first?.sourceSegmentIDs, segments.map(\.id))
    }

    func testSearchObservationMatchesEitherBilingualQueryAsACompleteVariant() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Planning", startedAt: Date())
        try await store.save(meeting)
        let spanish = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "La hoja de ruta queda lista en agosto",
            startTime: 3,
            endTime: 5,
            isFinal: true)
        let partial = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "La hoja de ruta no tiene fecha",
            startTime: 8,
            endTime: 10,
            isFinal: true)
        try await store.save([spanish, partial])

        var iterator = store.observeLibrarySearch(
            ["august roadmap", "agosto hoja de ruta"]
        ).makeAsyncIterator()
        let hits = try await nextSearch(&iterator)

        XCTAssertEqual(hits.map(\.segmentID), [spanish.id])
    }

    func testSearchObservationFoldsLatinAccentsWithoutChangingStoredText() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Planning", startedAt: Date())
        try await store.save(meeting)
        let accented = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "La reunión definió la migración del próximo trimestre.",
            startTime: 3,
            endTime: 5,
            isFinal: true)
        try await store.save([accented])

        var iterator = store.observeLibrarySearch("reunion").makeAsyncIterator()
        let hits = try await nextSearch(&iterator)

        XCTAssertEqual(hits.map(\.segmentID), [accented.id])
        XCTAssertEqual(hits.first?.text, accented.text)
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
