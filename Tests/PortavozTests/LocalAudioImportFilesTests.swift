import Foundation
import PlatformKit
import PortavozCore
import StorageKit
import XCTest

final class LocalAudioImportFilesTests: XCTestCase {
    func testRealBookmarkFollowsRenameAndCopiesEveryByteWithoutChangingOriginal() async throws {
        let fixture = try AudioImportFileFixture()
        defer { fixture.remove() }
        let request = try await fixture.selection()
        let renamed = fixture.directory.appendingPathComponent("Renamed — café Don’t.wav")
        try FileManager.default.moveItem(at: fixture.source, to: renamed)
        let copy = try await fixture.files.copySelectedAudio(request)
        XCTAssertEqual(try Data(contentsOf: renamed), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: copy.fileURL), fixture.bytes)
        XCTAssertEqual(copy.digest, ContentDigest.sha256(fixture.bytes))
        XCTAssertFalse(copy.fileURL.path.hasPrefix(renamed.path))
    }

    func testPublishedRealCopySurvivesMissingOriginalAndNewAdapter() async throws {
        let fixture = try AudioImportFileFixture()
        defer { fixture.remove() }
        let request = try await fixture.selection()
        let databaseURL = fixture.directory.appendingPathComponent("library.sqlite")
        let retained: AudioImportRequest
        do {
            let store = try MeetingStore(databaseURL: databaseURL)
            _ = try await store.enqueueAudioImports([request])
            let claimed = try await store.claimNextProcessingJob(kinds: [.audioImport], owner: "owner", leaseDuration: 30)
            let job = try XCTUnwrap(claimed)
            let copy = try await fixture.files.copySelectedAudio(request)
            retained = try await store.publishAudioImportCopy(for: job.id, owner: "owner",
                                                            relativeDirectory: copy.relativeDirectory, digest: copy.digest)
        }
        try FileManager.default.removeItem(at: fixture.source)
        let otherProcessFiles = LocalAudioImportFiles(root: fixture.root)
        let restored = try await otherProcessFiles.verifyOwnedAudio(retained)
        XCTAssertEqual(try Data(contentsOf: restored.fileURL), fixture.bytes)
        XCTAssertNil(retained.sourceBookmark)
    }

    func testSourceMutationAfterAdmissionRejectsWithoutCreatingOwnedAudio() async throws {
        let fixture = try AudioImportFileFixture()
        defer { fixture.remove() }
        let request = try await fixture.selection()
        let changed = Data(repeating: 71, count: fixture.bytes.count)
        try changed.write(to: fixture.source)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                                              ofItemAtPath: fixture.source.path)
        do {
            _ = try await fixture.files.copySelectedAudio(request)
            XCTFail("A queued file changed before reading cannot silently become the admitted input")
        } catch {
            XCTAssertEqual(error as? AudioImportFileError, .sourceChanged)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source), changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Audio").path))
    }

    func testSameLengthOwnedCorruptionFailsDigestVerification() async throws {
        let fixture = try AudioImportFileFixture()
        defer { fixture.remove() }
        var request = try await fixture.selection()
        let copy = try await fixture.files.copySelectedAudio(request)
        request.sourceBookmark = nil
        request.copiedAudioDirectory = copy.relativeDirectory
        request.copiedAudioDigest = copy.digest
        var changed = fixture.bytes
        changed[17] ^= 1
        try changed.write(to: copy.fileURL)
        do {
            _ = try await fixture.files.verifyOwnedAudio(request)
            XCTFail("The original byte count is not proof of intact copied content")
        } catch {
            XCTAssertEqual(error as? AudioImportFileError, .invalidOwnedCopy)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
    }

    func testReplacementWithSamePathSizeAndTimestampCannotBorrowSelectedIdentity() async throws {
        let fixture = try AudioImportFileFixture()
        defer { fixture.remove() }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: fixture.source.path)
        let request = try await fixture.selection()
        try FileManager.default.moveItem(at: fixture.source, to: fixture.directory.appendingPathComponent("old.wav"))
        let replacement = Data(repeating: 71, count: fixture.bytes.count)
        try replacement.write(to: fixture.source)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: fixture.source.path)
        let metadata = try URL(fileURLWithPath: fixture.source.path)
            .resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        XCTAssertEqual(metadata.fileSize, Int(request.sourceByteCount))
        XCTAssertEqual(metadata.contentModificationDate, request.sourceModifiedAt)
        // A bookmark-capable volume may follow the selected original after
        // rename; otherwise it must reject the replacement, never copy it.
        do {
            let copy = try await fixture.files.copySelectedAudio(request)
            XCTAssertEqual(try Data(contentsOf: copy.fileURL), fixture.bytes)
        } catch {
            XCTAssertEqual(error as? AudioImportFileError, .sourceChanged)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source), replacement)
    }

    func testPreCancelledCopyDoesNotReplaceAnExistingStage() async throws {
        let fixture = try AudioImportFileFixture()
        defer { fixture.remove() }
        let request = try await fixture.selection()
        let original = try await fixture.files.copySelectedAudio(request)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.files.copySelectedAudio(request)
        }
        do {
            _ = try await cancelled.value
            XCTFail("Pre-cancelled work must not start file acquisition")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: original.fileURL), fixture.bytes)
    }

    func testUnpublishedPartialIsReclaimedOnlyAfterSourceValidation() async throws {
        let fixture = try AudioImportFileFixture()
        defer { fixture.remove() }
        let request = try await fixture.selection()
        let original = try await fixture.files.copySelectedAudio(request)
        try Data([7, 8, 9]).write(to: original.fileURL)
        let replacement = try await fixture.files.copySelectedAudio(request)
        XCTAssertEqual(replacement.fileURL, original.fileURL)
        XCTAssertEqual(try Data(contentsOf: replacement.fileURL), fixture.bytes)
        try FileManager.default.removeItem(at: fixture.source)
        do {
            _ = try await fixture.files.copySelectedAudio(request)
            XCTFail("A missing original must not delete the last staged bytes")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: original.fileURL), fixture.bytes)
    }

    func testOwnedDirectorySymlinkCannotRedirectAWrite() async throws {
        let fixture = try AudioImportFileFixture()
        defer { fixture.remove() }
        let request = try await fixture.selection()
        let external = fixture.directory.appendingPathComponent("not-owned")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("Audio"),
                                                  withDestinationURL: external)
        do {
            _ = try await fixture.files.copySelectedAudio(request)
            XCTFail("An ancestor symlink cannot redirect acquisition outside the owned root")
        } catch {
            XCTAssertEqual(error as? AudioImportFileError, .invalidOwnedCopy)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
    }

    func testAcquisitionAccessRejectsOverlapAndReleasesAfterCancellation() async throws {
        let fixture = try AudioImportFileFixture()
        defer { fixture.remove() }
        let request = try await fixture.selection()
        let entered = expectation(description: "native acquisition lock is held")
        let hold = AsyncStream<Void>.makeStream()
        let active = Task {
            try await fixture.files.withAcquisitionAccess {
                entered.fulfill()
                for await _ in hold.stream { break }
                try Task.checkCancellation()
                return try await fixture.files.copySelectedAudio(request)
            }
        }
        defer { hold.continuation.finish(); active.cancel() }
        await fulfillment(of: [entered], timeout: 5)
        let otherAdapter = LocalAudioImportFiles(root: fixture.root)
        do {
            _ = try await otherAdapter.withAcquisitionAccess {
                XCTFail("A busy filesystem lease must never enter another operation")
                return try await otherAdapter.copySelectedAudio(request)
            }
            XCTFail("Acquisition must not block or steal another native writer")
        } catch { XCTAssertEqual(error as? AudioImportFileError, .acquisitionBusy) }
        active.cancel()
        do {
            _ = try await active.value
            XCTFail("Cancelled owner must propagate cancellation after releasing the lock")
        } catch { XCTAssertTrue(error is CancellationError) }
        let copy = try await otherAdapter.withAcquisitionAccess {
            try await otherAdapter.copySelectedAudio(request)
        }
        XCTAssertEqual(try Data(contentsOf: copy.fileURL), fixture.bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".audio-import.lock").path))
    }

    func testAcquisitionLockCannotFollowASymlink() async throws {
        let fixture = try AudioImportFileFixture()
        defer { fixture.remove() }
        let request = try await fixture.selection()
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent(".audio-import.lock"),
                                                  withDestinationURL: fixture.source)
        do {
            _ = try await fixture.files.withAcquisitionAccess {
                XCTFail("A foreign file cannot serve as the acquisition inode")
                return try await fixture.files.copySelectedAudio(request)
            }
            XCTFail("Symlink lock must reject acquisition")
        } catch { XCTAssertEqual(error as? AudioImportFileError, .copyFailed) }
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
    }
}

private struct AudioImportFileFixture: Sendable {
    let directory: URL
    let source: URL
    let root: URL
    let bytes: Data
    let files: LocalAudioImportFiles

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        source = directory.appendingPathComponent("English español café.wav")
        root = directory.appendingPathComponent("owned")
        let count = 3 * 256 * 1_024 + 19
        let samples: [UInt8] = (0..<count).map { UInt8($0 % 251) }
        bytes = Data(samples)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: source)
        files = LocalAudioImportFiles(root: root)
    }

    func selection() async throws -> AudioImportRequest {
        try await files.prepareSelection(source, meetingID: MeetingID(), title: "Audio — reunión",
                                         preferences: .init(transcriptLanguage: .automatic,
                                                            summaryLanguage: .followSpokenLanguage,
                                                            summaryFallbackLanguage: .english, vocabulary: []))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
