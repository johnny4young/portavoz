import ApplicationKit
import Foundation
import GRDB
import PlatformKit
import PortavozCore
import XCTest

@testable import StorageKit

final class AudioImportPurgeTests: XCTestCase {
    func testActualPurgeRemovesPendingStagedAndPublishedImportsWithoutTouchingOriginal() async throws {
        for phase in 0...2 {
            let fixture = try ImportQueueFixture()
            defer { fixture.remove() }
            let input = try await fixture.admit()
            if phase > 0 {
                let claimed = try await fixture.store.claimNextProcessingJob(
                    kinds: [.audioImport], owner: "interrupted", leaseDuration: 120)
                let job = try XCTUnwrap(claimed)
                let copy = try await fixture.files.withAcquisitionAccess {
                    try await fixture.files.copySelectedAudio(input)
                }
                if phase == 2 {
                    _ = try await fixture.store.publishAudioImportCopy(
                        for: job.id, owner: "interrupted", relativeDirectory: copy.relativeDirectory, digest: copy.digest)
                }
            }
            let detail = try await fixture.store.detail(input.meetingID)
            XCTAssertEqual(detail?.meeting.audioDirectory, input.copyDirectory)
            XCTAssertEqual(detail?.meeting.lifecycleState, .processing)
            try await DeleteMeeting(store: fixture.store)(input.meetingID)
            let result = try await fixture.purger()(PurgeMeetingRequest(meetingID: input.meetingID))
            XCTAssertTrue(result.audioRemovalSucceeded)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(input.copyDirectory).path))
            XCTAssertEqual(try Data(contentsOf: fixture.source), Data(repeating: 12, count: 1_024))
            try await fixture.store.database.read { database in
                for table in ["meeting", "processingJob", "audioImportInput"] {
                    XCTAssertEqual(try Int.fetchOne(database, sql: "SELECT count(*) FROM \(table)"), 0)
                }
            }
        }
    }

    func testPurgeUsesFreshTombstoneInsteadOfDeletingARestoredMeeting() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let input = try await fixture.admit()
        let copy = try await fixture.files.withAcquisitionAccess { try await fixture.files.copySelectedAudio(input) }
        try await fixture.store.delete(input.meetingID)
        let staleRow = try await fixture.store.deletedMeeting(input.meetingID)
        XCTAssertNotNil(staleRow)
        try await RestoreMeeting(store: fixture.store, acquisition: fixture.files)(input.meetingID)
        _ = try await fixture.purger()(PurgeMeetingRequest(meetingID: input.meetingID))
        let restored = try await fixture.store.detail(input.meetingID)
        XCTAssertNotNil(restored)
        XCTAssertEqual(try Data(contentsOf: copy.fileURL), try Data(contentsOf: fixture.source))
    }

    func testPurgeAndRestoreCannotPassAnOldWriterThenForgetItsStage() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let input = try await fixture.admit()
        let copied = expectation(description: "actual worker owns a staged copy")
        let hold = AsyncStream<Void>.makeStream()
        let files = HeldImportAcquisition(native: fixture.files, hold: hold.stream, didCopy: { copied.fulfill() })
        let worker = ProcessAudioImports(store: fixture.store, files: files,
                                         makeProcessor: { ImportQueueProcessor() }, summaries: ImportQueueSummary())
        let task = Task { try await worker.execute(.init()) }
        defer { hold.continuation.finish(); task.cancel() }
        await fulfillment(of: [copied], timeout: 5)
        try await fixture.store.delete(input.meetingID)
        do {
            _ = try await fixture.purger()(PurgeMeetingRequest(meetingID: input.meetingID))
            XCTFail("Busy acquisition must not delete the database authority")
        } catch { XCTAssertEqual(error as? AudioImportFileError, .acquisitionBusy) }
        do {
            try await RestoreMeeting(store: fixture.store, acquisition: fixture.files)(input.meetingID)
            XCTFail("Restore cannot revive an old writer while acquisition owns its directory")
        } catch { XCTAssertEqual(error as? AudioImportFileError, .acquisitionBusy) }
        let retained = try await fixture.store.deletedMeeting(input.meetingID)
        XCTAssertNotNil(retained)
        hold.continuation.finish()
        _ = try await task.value
        _ = try await fixture.purger()(PurgeMeetingRequest(meetingID: input.meetingID))
        let purged = try await fixture.store.deletedMeeting(input.meetingID)
        XCTAssertNil(purged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(input.copyDirectory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testRestoreCannotRaceBetweenFileRemovalAndDatabasePurge() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let input = try await fixture.admit()
        _ = try await fixture.files.withAcquisitionAccess { try await fixture.files.copySelectedAudio(input) }
        try await fixture.store.delete(input.meetingID)
        let removed = expectation(description: "files removed but purge transaction not reached")
        let hold = AsyncStream<Void>.makeStream()
        let files = ImportPurgeFiles(root: fixture.root, hold: hold.stream, didRemove: { removed.fulfill() })
        let purger = PurgeMeeting(store: fixture.store, audioFiles: files, acquisition: fixture.files)
        let task = Task { try await purger(PurgeMeetingRequest(meetingID: input.meetingID)) }
        defer { hold.continuation.finish(); task.cancel() }
        await fulfillment(of: [removed], timeout: 5)
        do {
            try await RestoreMeeting(store: fixture.store, acquisition: fixture.files)(input.meetingID)
            XCTFail("An in-flight purge cannot restore a row whose audio has been removed")
        } catch { XCTAssertEqual(error as? AudioImportFileError, .acquisitionBusy) }
        hold.continuation.finish()
        let result = try await task.value
        XCTAssertTrue(result.audioRemovalSucceeded)
        let purged = try await fixture.store.deletedMeeting(input.meetingID)
        XCTAssertNil(purged)
    }

    func testExpiredTrashAlsoPurgesReservedAudioWithoutACompletedTranscript() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let input = try await fixture.admit()
        _ = try await fixture.files.withAcquisitionAccess { try await fixture.files.copySelectedAudio(input) }
        try await fixture.store.delete(input.meetingID)
        let useCase = PurgeExpiredTrash(store: fixture.store, audioFiles: ImportPurgeFiles(root: fixture.root),
                                       acquisition: fixture.files)
        let count = try await useCase(Date().addingTimeInterval(1))
        XCTAssertEqual(count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(input.copyDirectory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testTrashExpiryRechecksTheCutoffAfterRestoreAndDeleteAgain() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let input = try await fixture.admit()
        let copy = try await fixture.files.withAcquisitionAccess { try await fixture.files.copySelectedAudio(input) }
        try await fixture.store.delete(input.meetingID)
        let cutoff = Date().addingTimeInterval(-60)
        try await fixture.store.database.write { database in
            try database.execute(sql: "UPDATE meeting SET deletedAt = ? WHERE id = ?",
                                 arguments: [cutoff.addingTimeInterval(-1), input.meetingID.rawValue.uuidString])
        }
        let store = RenewedTrashStore(store: fixture.store, meetingID: input.meetingID)
        let useCase = PurgeExpiredTrash(store: store, audioFiles: ImportPurgeFiles(root: fixture.root),
                                       acquisition: fixture.files)
        _ = try await useCase(cutoff)
        let renewed = try await fixture.store.deletedMeeting(input.meetingID)
        XCTAssertGreaterThan(try XCTUnwrap(renewed).deletedAt, cutoff)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.fileURL.path))
    }
}

/// A real restore/re-delete interleaving after expiry's snapshot was read.
private struct RenewedTrashStore: MeetingPurgeStore {
    let store: MeetingStore
    let meetingID: MeetingID
    func purge(_ id: MeetingID) async throws { try await store.purge(id) }
    func meetingPurgeCandidate(_ id: MeetingID) async throws -> MeetingPurgeCandidate? {
        try await store.meetingPurgeCandidate(id)
    }
    func meetingPurgeCandidates() async throws -> [MeetingPurgeCandidate] {
        let old = try await store.meetingPurgeCandidates()
        try await store.restore(meetingID)
        try await store.delete(meetingID)
        return old
    }
}

private extension ImportQueueFixture {
    func purger() -> PurgeMeeting {
        PurgeMeeting(store: store, audioFiles: ImportPurgeFiles(root: root), acquisition: files)
    }
}

private struct ImportPurgeFiles: MeetingAudioFiles {
    let root: URL
    var hold: AsyncStream<Void>?
    var didRemove: @Sendable () -> Void = {}

    func removeAudioDirectory(_ relativePath: String) async throws {
        let directory = root.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        didRemove()
        if let hold { for await _ in hold { break } }
    }
}
