import ApplicationKit
import Foundation
import PortavozCore
import XCTest
@testable import portavoz_app

@MainActor
final class AudioImportQueueModelTests: XCTestCase {
    func testScriptedRecognitionCannotBeEnabledWithoutTemporaryStoreAndExplicitFixture() async {
        for arguments in [[], ["-audio-import-ui-fixture"], ["-use-temp-store"],
                          ["-use-temp-store", "-audio-import-hold-first"],
                          ["-use-temp-store", "-audio-import-fail-mutations-once", "-audio-import-expired-owner"]] {
            XCTAssertNil(AudioImportUITestFixture.makeIfRequested(arguments: arguments))
        }
        XCTAssertNotNil(AudioImportUITestFixture.makeIfRequested(
            arguments: ["-use-temp-store", "-audio-import-ui-fixture"]))
    }

    func testMutationFixtureFailuresAreOneShotAndClockAdvancesOnlyWhenRequested() async throws {
        let ordinary = try XCTUnwrap(AudioImportUITestFixture.makeIfRequested(
            arguments: ["-use-temp-store", "-audio-import-ui-fixture"]))
        XCTAssertEqual(ordinary.clockOffset, 0)
        try await ordinary.beforeCancellation()
        try await ordinary.beforeLibraryDeletion()
        let faults = try XCTUnwrap(AudioImportUITestFixture.makeIfRequested(arguments: [
            "-use-temp-store", "-audio-import-ui-fixture", "-audio-import-fail-mutations-once",
            "-audio-import-expired-owner"]))
        XCTAssertEqual(faults.clockOffset, 121)
        do { try await faults.beforeCancellation(); XCTFail("fixture must reject first cancel") }
        catch { XCTAssertTrue(error is AudioImportQueueError) }
        try await faults.beforeCancellation()
        do { try await faults.beforeLibraryDeletion(); XCTFail("fixture must reject first deletion") }
        catch { XCTAssertTrue(error is AudioImportQueueError) }
        try await faults.beforeLibraryDeletion()
    }

    func testDismissalResubscribesAfterObservationFailureWithoutReplayingWork() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        _ = try await fixture.admit()
        let client = ImportQueueModelClient(fixture: fixture)
        client.observationFailures = 1
        let model = AudioImportQueueModel(client: client)
        model.showPage(0)
        try await waitForState { model.error != nil }
        model.dismissError()
        try await waitForState { model.page.total == 1 }
        XCTAssertNil(model.error)
        XCTAssertEqual(model.page.entries.first?.job.state, .pending)
        XCTAssertFalse(model.isDraining, "Dismissing a read error is not consent to retry processing")
        await model.suspend()
    }

    func testActualAdmissionDrainsTwoLanguagesAndKeepsOriginalBytes() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let completed = expectation(description: "queue drained")
        let client = ImportQueueModelClient(fixture: fixture, onFinish: { completed.fulfill() })
        let model = AudioImportQueueModel(client: client)
        let original = try Data(contentsOf: fixture.source)
        try await model.admit([fixture.source, fixture.source])
        await fulfillment(of: [completed], timeout: 10)
        let page = try await fixture.store.audioImportQueuePage()
        XCTAssertEqual(page.entries.count, 2)
        XCTAssertTrue(page.entries.allSatisfy { $0.job.state == .succeeded })
        XCTAssertEqual(page.unfinished, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.source), original)
        XCTAssertFalse(model.isDraining)
        XCTAssertNil(model.error)
        let state = await client.processor.state()
        XCTAssertEqual(state.maximumConcurrent, 1)
        XCTAssertEqual(state.releaseCount, 2)
        await model.suspend()
    }

    func testCancelDuringRealTranscriptionRejectsLateOutputAndContinuesOtherFile() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let completed = expectation(description: "replacement drain finished")
        let hold = AsyncStream<Void>.makeStream()
        let processor = ImportQueueProcessor(hold: hold.stream)
        completed.expectedFulfillmentCount = 2
        let client = ImportQueueModelClient(fixture: fixture, processor: processor, onFinish: { completed.fulfill() })
        let model = AudioImportQueueModel(client: client)
        // Admit first alone so cancellation cannot accidentally target the second.
        try await model.admit([fixture.source])
        let current = try await awaitCurrent(model)
        try await model.admit([fixture.source])
        await model.cancel(current)
        hold.continuation.finish()
        await fulfillment(of: [completed], timeout: 10)
        let page = try await fixture.store.audioImportQueuePage()
        XCTAssertEqual(page.entries.first { $0.id == current }?.job.state, .cancelled)
        XCTAssertEqual(page.entries.filter { $0.job.state == .succeeded }.count, 1)
        let detail = try await fixture.store.detail(current)
        XCTAssertTrue(detail?.segments.isEmpty == true)
        XCTAssertNil(model.error)
        client.onFinish = {}
        await model.suspend()
    }

    func testSuspendAndNewSupervisorResumePublishedCopyWithoutOriginal() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let entered = expectation(description: "copy published, transcription held")
        let hold = AsyncStream<Void>.makeStream()
        let client = ImportQueueModelClient(fixture: fixture,
            processor: ImportQueueProcessor(hold: hold.stream, onTranscribe: { entered.fulfill() }))
        let model = AudioImportQueueModel(client: client)
        try await model.admit([fixture.source])
        await fulfillment(of: [entered], timeout: 10)
        await model.suspend()
        let pending = try await fixture.store.audioImportQueuePage()
        XCTAssertEqual(pending.entries.first?.job.state, .pending)
        try FileManager.default.removeItem(at: fixture.source)
        let completed = expectation(description: "new supervisor finished")
        let nextClient = ImportQueueModelClient(fixture: fixture, onFinish: { completed.fulfill() })
        let next = AudioImportQueueModel(client: nextClient)
        next.start()
        await fulfillment(of: [completed], timeout: 10)
        let resumed = try await fixture.store.audioImportQueuePage()
        XCTAssertEqual(resumed.entries.first?.job.state, .succeeded)
        await next.suspend()
    }

    func testStorageMoveExcludesAdmissionAndDoesNotInventSuccess() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let client = ImportQueueModelClient(fixture: fixture)
        let model = AudioImportQueueModel(client: client)
        try model.beginStorageMove()
        do {
            try await model.admit([fixture.source])
            XCTFail("Admission cannot race a recordings-root move")
        } catch {}
        let page = try await fixture.store.audioImportQueuePage()
        XCTAssertEqual(page.total, 0)
        XCTAssertFalse(model.isAdmitting)
        model.endStorageMove()
        await model.suspend()
    }

    private func waitForState(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw QueueModelTestError.timeout
    }

    private func awaitCurrent(_ model: AudioImportQueueModel) async throws -> MeetingID {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let id = model.currentID, model.phase == .transcribing { return id }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw QueueModelTestError.timeout
    }
}

private enum QueueModelTestError: Error { case timeout }

@MainActor
private final class ImportQueueModelClient: AudioImportQueueClient {
    let fixture: ImportQueueFixture
    let processor: ImportQueueProcessor
    var onFinish: () -> Void
    var observationFailures = 0

    init(fixture: ImportQueueFixture, processor: ImportQueueProcessor = ImportQueueProcessor(),
         onFinish: @escaping () -> Void = {}) {
        self.fixture = fixture
        self.processor = processor
        self.onFinish = onFinish
    }
    func observeAudioImports(offset: Int) -> AsyncThrowingStream<AudioImportQueuePage, Error> {
        if observationFailures > 0 {
            observationFailures -= 1
            return AsyncThrowingStream { $0.finish(throwing: QueueModelTestError.timeout) }
        }
        return fixture.store.observeAudioImportQueue(offset: offset)
    }
    func admitAudioImports(_ urls: [URL]) async throws {
        var inputs: [AudioImportRequest] = []
        for (index, url) in urls.enumerated() {
            inputs.append(try await fixture.files.prepareSelection(
                url, meetingID: MeetingID(), title: "Synthetic audio \(index)",
                preferences: .init(transcriptLanguage: index == 0 ? .fixed(.spanish) : .fixed(.english),
                                   summaryLanguage: .followSpokenLanguage,
                                   summaryFallbackLanguage: .english, vocabulary: ["Don’t", "café"])))
        }
        _ = try await fixture.store.enqueueAudioImports(inputs)
    }
    func makeAudioImportWorker() -> ProcessAudioImports { fixture.worker(processor) }
    func nextAudioImportWake() async throws -> Date? {
        try await fixture.store.nextScheduledProcessingDate(kinds: [.audioImport])
    }
    func cancelAudioImport(_ id: MeetingID) async throws { try await fixture.store.cancelAudioImport(for: id) }
    func retryAudioImport(_ id: MeetingID) async throws { try await fixture.store.retryAudioImport(for: id) }
    func audioImportWorkFinished() { onFinish() }
}
