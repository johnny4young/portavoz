import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class AudioImportAdmissionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_200_000)

    private func input(
        id: MeetingID = MeetingID(), title: String = "Don't delete — no borres: café",
        fileExtension: String = "wav", bookmark: Data = Data("synthetic capability".utf8)
    ) -> AudioImportRequest {
        AudioImportRequest(
            meetingID: id, title: title, fileExtension: fileExtension,
            sourceByteCount: 240, sourceModifiedAt: now, sourceBookmark: bookmark,
            preferences: ImportMeetingPreferencesSnapshot(
                transcriptLanguage: .automatic, summaryLanguage: .fixed(.spanish),
                summaryFallbackLanguage: .english, vocabulary: ["C++", "café", "Don’t"]))
    }

    func testPopulatedV51MigrationAndReopenRetainInputAndExistingMeeting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("library.sqlite")
        let legacyMeeting = Meeting(title: "Existing — existente", startedAt: now)
        do {
            let legacy = try DatabaseQueue(path: url.path)
            try StorageSchema.migrator().migrate(legacy, upTo: "v51")
            try await legacy.write { [now] database in
                try MeetingRecord(legacyMeeting, createdAt: now, updatedAt: now).insert(database)
            }
        }
        let request = input()
        let originalID: ProcessingJobID
        do {
            let store = try MeetingStore(databaseURL: url)
            let jobs = try await store.enqueueAudioImports([request], at: now)
            originalID = try XCTUnwrap(jobs.first).id
        }
        let reopened = try MeetingStore(databaseURL: url)
        let retained = try await reopened.detail(legacyMeeting.id)
        XCTAssertEqual(retained?.meeting.title, legacyMeeting.title)
        let jobs = try await reopened.enqueueAudioImports([request], at: now.addingTimeInterval(10))
        XCTAssertEqual(jobs.map(\.id), [originalID])
        let claimed = try await reopened.claimNextProcessingJob(
            kinds: [.audioImport], owner: "test-owner", leaseDuration: 30, at: now)
        XCTAssertEqual(claimed?.id, originalID)
        let restored = try await reopened.audioImportInput(for: originalID, owner: "test-owner", at: now)
        XCTAssertEqual(restored, request)
        let pending = try await reopened.detail(request.meetingID)
        XCTAssertEqual(pending?.meeting.lifecycleState, .processing)
        XCTAssertTrue(pending?.segments.isEmpty == true)
        try await reopened.database.read { database in
            XCTAssertEqual(try String.fetchOne(database, sql: "PRAGMA integrity_check"), "ok")
            XCTAssertTrue(try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testConflictingLaterFileRollsBackWholeAdmissionAndDoesNotReplaceExistingMeeting() async throws {
        let store = try MeetingStore.inMemory()
        let original = input()
        _ = try await store.enqueueAudioImports([original], at: now)
        let newFile = input(title: "New — nueva")
        do {
            _ = try await store.enqueueAudioImports([
                newFile, input(id: original.meetingID, title: "Wrong replacement")
            ], at: now)
            XCTFail("A changed request may not reuse the existing operation identity")
        } catch {}
        let rolledBack = try await store.detail(newFile.meetingID)
        let retained = try await store.detail(original.meetingID)
        XCTAssertNil(rolledBack)
        XCTAssertEqual(retained?.meeting.title, original.title)
    }

    func testAdmissionRejectsEmptyCapabilitiesDuplicateIdentitiesAndPathExtensions() async throws {
        let store = try MeetingStore.inMemory()
        let repeated = input()
        for requests in [[], [input(bookmark: Data())], [repeated, repeated],
                         [input(fileExtension: "../wav")], [input(title: " \n\t")]] {
            do {
                _ = try await store.enqueueAudioImports(requests, at: now)
                XCTFail("Invalid selection must reject before any admission")
            } catch {}
        }
        try await store.database.read { database in
            XCTAssertEqual(try Int.fetchOne(database, sql: "SELECT count(*) FROM audioImportInput"), 0)
        }
    }

    func testCancellingQueuedAndRunningImportsNeverMakesAnEmptyMeetingReady() async throws {
        for claimFirst in [false, true] {
            let store = try MeetingStore.inMemory()
            let request = input()
            let jobs = try await store.enqueueAudioImports([request], at: now)
            let jobID = try XCTUnwrap(jobs.first).id
            if claimFirst {
                _ = try await store.claimNextProcessingJob(
                    kinds: [.audioImport], owner: "old-owner", leaseDuration: 30, at: now)
            }
            let cancelled = try await store.cancelAudioImport(for: request.meetingID, at: now)
            let repeated = try await store.cancelAudioImport(for: request.meetingID, at: now.addingTimeInterval(1))
            XCTAssertEqual(cancelled, repeated)
            XCTAssertEqual(cancelled.state, .cancelled)
            let detail = try await store.detail(request.meetingID)
            XCTAssertEqual(detail?.meeting.lifecycleState, .needsAttention)
            XCTAssertEqual(detail?.meeting.lastProcessingError, "import.cancelled")
            do {
                _ = try await store.audioImportInput(for: jobID, owner: "old-owner", at: now)
                XCTFail("Cancellation must retire access to the source capability")
            } catch {}
        }
    }

    func testRequiredImportCannotUseGenericCompletionWithoutAnArtifact() async throws {
        let store = try MeetingStore.inMemory()
        _ = try await store.enqueueAudioImports([input()], at: now)
        let next = try await store.claimNextProcessingJob(
            kinds: [.audioImport], owner: "owner", leaseDuration: 30, at: now)
        let job = try XCTUnwrap(next)
        do {
            _ = try await store.completeProcessingJob(job.id, owner: "owner", at: now)
            XCTFail("An import needs atomic artifact publication, never control-plane success alone")
        } catch {}
        let detail = try await store.detail(job.meetingID)
        XCTAssertEqual(detail?.meeting.lifecycleState, .processing)
    }

    func testCorruptedPayloadCannotChangeTheAdmittedSourceCapability() async throws {
        let store = try MeetingStore.inMemory()
        let request = input()
        _ = try await store.enqueueAudioImports([request], at: now)
        let next = try await store.claimNextProcessingJob(
            kinds: [.audioImport], owner: "owner", leaseDuration: 30, at: now)
        let job = try XCTUnwrap(next)
        let replacement = input(id: request.meetingID, bookmark: Data("another capability".utf8))
        let payload = try JSONEncoder().encode(replacement)
        try await store.database.write { database in
            try database.execute(sql: "UPDATE audioImportInput SET payload = ?", arguments: [payload])
        }
        do {
            _ = try await store.audioImportInput(for: job.id, owner: "owner", at: now)
            XCTFail("A valid JSON shape does not prove the admitted source identity")
        } catch {}
    }
    func testDeletedMeetingRevokesAnOtherwiseCurrentSourceLease() async throws {
        let store = try MeetingStore.inMemory()
        let request = input()
        _ = try await store.enqueueAudioImports([request], at: now)
        let next = try await store.claimNextProcessingJob(
            kinds: [.audioImport], owner: "owner", leaseDuration: 30, at: now)
        let job = try XCTUnwrap(next)
        try await store.delete(request.meetingID)
        do {
            _ = try await store.audioImportInput(for: job.id, owner: "owner", at: now)
            XCTFail("A still-current lease cannot read a deleted source capability")
        } catch {}
    }

    func testCorruptedJobKindCannotCancelAnotherCapability() async throws {
        let store = try MeetingStore.inMemory()
        let request = input()
        _ = try await store.enqueueAudioImports([request], at: now)
        try await store.database.write { database in
            try database.execute(sql: "UPDATE processingJob SET kind = 'summary'")
        }
        do {
            _ = try await store.cancelAudioImport(for: request.meetingID, at: now)
            XCTFail("Import cancellation cannot acquire authority over another job kind")
        } catch {}
        let jobs = try await store.processingJobs(for: request.meetingID)
        XCTAssertEqual(jobs.first?.state, .pending)
    }

    func testEncodedPayloadAcceptsExactBoundaryAndRejectsOneByteMoreWithoutTruncation() async throws {
        let store = try MeetingStore.inMemory()
        let base = input(title: "x")
        let count = try JSONEncoder().encode(base).count
        let title = String(repeating: "x", count: 1_048_576 - count + 1)
        let exact = input(id: base.meetingID, title: title)
        _ = try await store.enqueueAudioImports([exact], at: now)
        do {
            _ = try await store.enqueueAudioImports([input(title: title + "x")], at: now)
            XCTFail("Oversized metadata must reject, not silently truncate user input")
        } catch {}
        try await store.database.read { database in
            XCTAssertEqual(try Int.fetchOne(database, sql: "SELECT length(payload) FROM audioImportInput"), 1_048_576)
            XCTAssertEqual(try Int.fetchOne(database, sql: "SELECT count(*) FROM meeting"), 1)
        }
    }

    func testSelectionMetadataBudgetRejectsBeforeAnyMeetingIsAdmitted() async throws {
        let store = try MeetingStore.inMemory()
        let title = String(repeating: "x", count: 1_000_000)
        let requests = (0..<17).map { _ in input(title: title) }
        do {
            _ = try await store.enqueueAudioImports(requests, at: now)
            XCTFail("Many individually valid inputs cannot create an unbounded metadata allocation")
        } catch {}
        try await store.database.read { database in
            XCTAssertEqual(try Int.fetchOne(database, sql: "SELECT count(*) FROM meeting"), 0)
        }
    }

    func testNegativeInfinityDoesNotPublishInvalidMeetingDates() async throws {
        let store = try MeetingStore.inMemory()
        do {
            _ = try await store.enqueueAudioImports([input()], at: Date(timeIntervalSince1970: -.infinity))
            XCTFail("Nonfinite admission time must reject before SQLite encoding")
        } catch {}
        try await store.database.read { database in
            XCTAssertEqual(try Int.fetchOne(database, sql: "SELECT count(*) FROM meeting"), 0)
        }
    }
}
