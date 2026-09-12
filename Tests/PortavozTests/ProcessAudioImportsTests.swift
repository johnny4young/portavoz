import ApplicationKit
import DiarizationKit
import Foundation
import IntelligenceKit
import PlatformKit
import PortavozCore
@testable import StorageKit
import TranscriptionKit
import XCTest

final class ProcessAudioImportsTests: XCTestCase {
    func testRealFileQueuePreservesIndependentLanguagesSummaryAndSerialRelease() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let spanish = try await fixture.admit(language: .fixed(.spanish), summary: .fixed(.english))
        let english = try await fixture.admit(language: .fixed(.english), summary: .fixed(.spanish))
        let processor = ImportQueueProcessor()
        let count = try await fixture.worker(processor).execute(.init())
        XCTAssertEqual(count, 2)
        let expected = [(spanish, "No envíes 2. Don’t.", "en"), (english, "Don’t send 2. Café.", "es")]
        for (request, text, summaryLanguage) in expected {
            let detail = try await fixture.store.detail(request.meetingID)
            XCTAssertEqual(detail?.meeting.lifecycleState, .ready)
            XCTAssertEqual(detail?.segments.map(\.text), [text])
            let summary = try await fixture.store.summary(request.meetingID)
            XCTAssertEqual(summary?.draft.language, summaryLanguage)
            let run = try await fixture.store.generationRun(forSummary: request.meetingID)
            XCTAssertEqual(run?.transcriptRevisionSource, .revision(1))
            XCTAssertEqual(run?.outcome, .succeeded)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        }
        let state = await processor.state()
        XCTAssertEqual(state.releaseCount, 2)
        XCTAssertEqual(state.maximumConcurrent, 1)
        XCTAssertEqual(state.diarizerPreparationCount, 4)
        XCTAssertEqual(state.vocabularies, [["C++", "café"], ["C++", "café"]])
    }

    func testRequiredFailureKeepsCopyAndNextFileRunsThenRetryNeedsNoOriginal() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let failedInput = try await fixture.admit()
        let other = try await fixture.admit()
        let processor = ImportQueueProcessor(failFirst: true)
        _ = try await fixture.worker(processor).execute(.init())
        let firstDetail = try await fixture.store.detail(failedInput.meetingID)
        let nextDetail = try await fixture.store.detail(other.meetingID)
        XCTAssertEqual(firstDetail?.meeting.lifecycleState, .needsAttention)
        XCTAssertEqual(firstDetail?.meeting.lastProcessingError, "import.processing.failed")
        XCTAssertTrue(firstDetail?.segments.isEmpty == true)
        XCTAssertNotNil(firstDetail?.meeting.audioDirectory)
        XCTAssertEqual(nextDetail?.meeting.lifecycleState, .ready)
        let originalJobs = try await fixture.store.processingJobs(for: failedInput.meetingID)
        try FileManager.default.removeItem(at: fixture.source)
        _ = try await fixture.store.retryAudioImport(for: failedInput.meetingID)
        _ = try await fixture.worker(processor).execute(.init())
        let completed = try await fixture.store.detail(failedInput.meetingID)
        let finalJobs = try await fixture.store.processingJobs(for: failedInput.meetingID)
        XCTAssertEqual(completed?.meeting.lifecycleState, .ready)
        XCTAssertEqual(completed?.meeting.audioDirectory, firstDetail?.meeting.audioDirectory)
        XCTAssertEqual(finalJobs.map(\.id), originalJobs.map(\.id))
    }

    func testUserCancellationStopsHeldWorkAndRejectsItsLateTranscript() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let input = try await fixture.admit()
        let started = expectation(description: "real import reached transcriber")
        let hold = AsyncStream<Void>.makeStream()
        let processor = ImportQueueProcessor(hold: hold.stream, onTranscribe: { started.fulfill() })
        let worker = fixture.worker(processor)
        let task = Task { try await worker.execute(.init()) }
        defer { hold.continuation.finish(); task.cancel() }
        await fulfillment(of: [started], timeout: 5)
        _ = try await fixture.store.cancelAudioImport(for: input.meetingID)
        _ = try await task.value
        let detail = try await fixture.store.detail(input.meetingID)
        XCTAssertEqual(detail?.meeting.lastProcessingError, "import.cancelled")
        XCTAssertTrue(detail?.segments.isEmpty == true)
        XCTAssertNotNil(detail?.meeting.audioDirectory)
        let state = await processor.state()
        XCTAssertEqual(state.releaseCount, 1)
        XCTAssertEqual(state.lateResults, 1)
    }

    func testTaskCancellationSuspendsAndRelaunchResumesSameCopyAndIdentity() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let input = try await fixture.admit()
        let started = expectation(description: "processing can now be interrupted")
        let hold = AsyncStream<Void>.makeStream()
        let processor = ImportQueueProcessor(hold: hold.stream, onTranscribe: { started.fulfill() })
        let worker = fixture.worker(processor)
        let task = Task { try await worker.execute(.init()) }
        defer { hold.continuation.finish(); task.cancel() }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Process interruption must not report a completed import")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let suspended = try await fixture.store.processingJobs(for: input.meetingID)
        XCTAssertEqual(suspended.first?.state, .pending)
        try FileManager.default.removeItem(at: fixture.source)
        let reopened = try MeetingStore(databaseURL: fixture.databaseURL)
        let resumed = ProcessAudioImports(store: reopened, files: LocalAudioImportFiles(root: fixture.root),
                                          makeProcessor: { ImportQueueProcessor() }, summaries: ImportQueueSummary())
        _ = try await resumed.execute(.init())
        let detail = try await reopened.detail(input.meetingID)
        let completed = try await reopened.processingJobs(for: input.meetingID)
        XCTAssertEqual(detail?.meeting.lifecycleState, .ready)
        XCTAssertEqual(completed.map(\.id), suspended.map(\.id))
        XCTAssertEqual(completed.first?.state, .succeeded)
    }

    func testCancellationAfterNativeCopyReopensTheSameReservedStage() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let input = try await fixture.admit()
        let copied = expectation(description: "native copy completed before SQLite publication")
        let hold = AsyncStream<Void>.makeStream()
        let files = HeldImportAcquisition(native: fixture.files, hold: hold.stream, didCopy: { copied.fulfill() })
        let worker = fixture.worker(ImportQueueProcessor(), files: files)
        let task = Task { try await worker.execute(.init()) }
        defer { hold.continuation.finish(); task.cancel() }
        await fulfillment(of: [copied], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation at publication must leave pending work, not success")
        } catch { XCTAssertTrue(error is CancellationError) }
        let stage = fixture.root.appendingPathComponent(input.copyDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.path), ["system.wav"])
        let detail = try await fixture.store.detail(input.meetingID)
        XCTAssertEqual(detail?.meeting.audioDirectory, input.copyDirectory)
        let reopened = try MeetingStore(databaseURL: fixture.databaseURL)
        let resumed = ProcessAudioImports(store: reopened, files: LocalAudioImportFiles(root: fixture.root),
                                          makeProcessor: { ImportQueueProcessor() }, summaries: ImportQueueSummary())
        _ = try await resumed.execute(.init())
        let completed = try await reopened.detail(input.meetingID)
        XCTAssertEqual(completed?.meeting.audioDirectory, input.copyDirectory)
        XCTAssertEqual(completed?.meeting.lifecycleState, .ready)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.deletingLastPathComponent().path),
                       [input.copyID.uuidString])
    }

    func testRejectedCopyPublicationRetainsKnownStageAndExplicitRetryReclaimsIt() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let input = try await fixture.admit()
        try await fixture.store.database.write { database in
            try database.execute(sql: """
                CREATE TRIGGER reject_copy BEFORE UPDATE ON audioImportInput
                BEGIN SELECT RAISE(ABORT, 'synthetic copy publication rejection'); END
                """)
        }
        let processor = ImportQueueProcessor()
        _ = try await fixture.worker(processor).execute(.init())
        let failed = try await fixture.store.detail(input.meetingID)
        XCTAssertEqual(failed?.meeting.audioDirectory, input.copyDirectory)
        XCTAssertEqual(failed?.meeting.lifecycleState, .needsAttention)
        let state = await processor.state()
        XCTAssertEqual(state.maximumConcurrent, 0)
        let stage = fixture.root.appendingPathComponent(input.copyDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
        try await fixture.store.database.write { try $0.execute(sql: "DROP TRIGGER reject_copy") }
        _ = try await fixture.store.retryAudioImport(for: input.meetingID)
        _ = try await fixture.worker(processor).execute(.init())
        let completed = try await fixture.store.detail(input.meetingID)
        XCTAssertEqual(completed?.meeting.audioDirectory, input.copyDirectory)
        XCTAssertEqual(completed?.meeting.lifecycleState, .ready)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.deletingLastPathComponent().path),
                       [input.copyID.uuidString])
    }

    func testExpiredOwnerCannotBeReclaimedWhileItsNativeAcquisitionStillRuns() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let input = try await fixture.admit()
        let copied = expectation(description: "old native owner is still holding acquisition access")
        let hold = AsyncStream<Void>.makeStream()
        let files = HeldImportAcquisition(native: fixture.files, hold: hold.stream, didCopy: { copied.fulfill() })
        let worker = ProcessAudioImports(store: fixture.store, files: files,
                                         makeProcessor: { ImportQueueProcessor() }, summaries: ImportQueueSummary())
        let oldTask = Task { try await worker.execute(.init()) }
        defer { hold.continuation.finish(); oldTask.cancel() }
        await fulfillment(of: [copied], timeout: 5)
        try await fixture.store.database.write { database in
            try database.execute(sql: "UPDATE processingJob SET leaseExpiresAt = ? WHERE meetingID = ?",
                                 arguments: [Date().addingTimeInterval(-1), input.meetingID.rawValue.uuidString])
        }
        let contender = ImportQueueProcessor()
        _ = try await fixture.worker(contender).execute(.init())
        let busy = try await fixture.store.detail(input.meetingID)
        XCTAssertEqual(busy?.meeting.lastProcessingError, "import.copy.busy")
        let state = await contender.state()
        XCTAssertEqual(state.maximumConcurrent, 0)
        hold.continuation.finish()
        _ = try await oldTask.value
        let retained = try await fixture.store.detail(input.meetingID)
        XCTAssertEqual(retained?.meeting.audioDirectory, input.copyDirectory)
        XCTAssertTrue(retained?.segments.isEmpty == true)
        _ = try await fixture.store.retryAudioImport(for: input.meetingID)
        _ = try await fixture.worker(contender).execute(.init())
        let completed = try await fixture.store.detail(input.meetingID)
        XCTAssertEqual(completed?.meeting.lifecycleState, .ready)
        XCTAssertEqual(completed?.meeting.audioDirectory, input.copyDirectory)
    }

    func testMissingSourcePreservesActionableFailureWithoutPreparingModels() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let input = try await fixture.admit()
        try FileManager.default.removeItem(at: fixture.source)
        let processor = ImportQueueProcessor()
        _ = try await fixture.worker(processor).execute(.init())
        let detail = try await fixture.store.detail(input.meetingID)
        XCTAssertEqual(detail?.meeting.lifecycleState, .needsAttention)
        XCTAssertEqual(detail?.meeting.lastProcessingError, "import.source.unavailable")
        let state = await processor.state()
        XCTAssertEqual(state.maximumConcurrent, 0)
    }
}
