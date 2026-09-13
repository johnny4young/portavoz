import Foundation
import ModelStoreKit
import PortavozCore
import TranscriptionKit
import XCTest

@testable import portavoz_app

/// Opt-in real weights, no inference or audio. Deterministic scheduling tests
/// do not substitute for this concrete engine/lease lifetime check.
@MainActor
final class ModelMemoryResidencyIntegrationTests: XCTestCase {
    func testLightweightProfileRetainsRealSpeechUntilBothOwnersFinish() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PORTAVOZ_MODEL_RESIDENCY_TESTS"] == "1",
            "set PORTAVOZ_MODEL_RESIDENCY_TESTS=1 with verified Parakeet assets installed")
        let store = ModelStore()
        let descriptor = ModelCatalog.parakeetTdtV3
        let report = await store.verify(descriptor)
        try XCTSkipUnless(report.isComplete, "complete pinned Parakeet assets are required; this test never downloads")
        let directory = await store.directory(for: descriptor)
        var engine: ParakeetEngine? = try await ParakeetEngine.load(fromVerifiedDirectory: directory)
        weak let observedEngine = engine
        let suite = "model-memory-real-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = try AppServices(arguments: ["portavoz-app", "-use-temp-store"], defaults: defaults)
        let ticket = try XCTUnwrap(services.modelResidencyLedger.beginLoad(.liveSpeech))
        XCTAssertTrue(services.modelResidencyLedger.finishLoad(ticket, measuredFootprintBytes: nil))
        services.transcriber = engine
        engine = nil

        // Enter the real resident-only acquisition seam twice, as independent
        // recording and dictation borrowers do. No fabricated engine is used.
        var recording = try services.acquireResidentLiveSpeechRuntime()
        var dictation = try services.acquireResidentLiveSpeechRuntime()
        XCTAssertNotNil(recording)
        XCTAssertNotNil(dictation)
        services.setModelMemoryProfile(.lightweight)
        try await waitForDeadlines(services)
        XCTAssertNotNil(observedEngine)
        XCTAssertTrue(services.transcriber === observedEngine)
        XCTAssertFalse(services.releaseLiveSpeechRuntime())

        XCTAssertTrue(services.finishLiveSpeechRuntime(try XCTUnwrap(dictation)))
        dictation = nil
        services.scheduleRecordingEnginesRelease()
        try await waitForDeadlines(services)
        XCTAssertTrue(services.transcriber === observedEngine)
        XCTAssertFalse(services.releaseLiveSpeechRuntime())

        XCTAssertTrue(services.finishLiveSpeechRuntime(try XCTUnwrap(recording)))
        recording = nil
        services.scheduleRecordingEnginesRelease()
        try await waitForDeadlines(services)
        XCTAssertNil(services.transcriber)
        XCTAssertNil(observedEngine, "the idle scheduler must not retain the real engine")
        XCTAssertEqual(services.modelResidencyLedger.record(for: .liveSpeech).status, .unloaded)
        let after = await store.verify(descriptor)
        XCTAssertTrue(after.isComplete, "releasing weights must leave verified model files intact")
    }

    private func waitForDeadlines(_ services: AppServices) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while services.modelIdleReleaseScheduler.pendingCount > 0 {
            guard ContinuousClock.now < deadline else { return XCTFail("model release did not settle") }
            await Task.yield()
        }
    }
}
