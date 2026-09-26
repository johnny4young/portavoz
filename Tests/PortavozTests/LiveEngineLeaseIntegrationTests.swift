import Foundation
import ModelStoreKit
import PortavozCore
import TranscriptionKit
import XCTest

@testable import portavoz_app

/// Opt-in real-weight coverage of the composition call sites. Ordinary CI
/// exercises the injected dictation/recording failures without downloading.
@MainActor
final class LiveEngineLeaseIntegrationTests: XCTestCase {
    func testCancelledDictationCallSiteNeverStartsSharedModelPreparation() async throws {
        let suite = "cancelled-live-lease-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = try AppServices(arguments: ["portavoz-app", "-use-temp-store"], defaults: defaults)
        let (stream, gate) = AsyncStream.makeStream(of: Void.self)
        let task = Task { @MainActor in
            for await _ in stream { break }
            return try await DictationSessionDependencies.live(services: services).acquireRuntime()
        }
        task.cancel()
        gate.finish()
        do {
            _ = try await task.value
            XCTFail("pre-cancelled dictation must not acquire a live model")
        } catch is CancellationError {
            // Expected; no model-load task or residency ticket may be left.
        } catch {
            XCTFail("expected cancellation, got \(type(of: error))")
        }
        XCTAssertNil(services.liveSpeechRuntimeLoad)
        XCTAssertNil(services.transcriber)
        XCTAssertEqual(services.modelResidencyLedger.record(for: .liveSpeech).status, .unloaded)
    }

    func testRecordingAndDictationBorrowTheSameResidentEngineIndependently() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PORTAVOZ_LIVE_LEASE_TESTS"] == "1",
            "set PORTAVOZ_LIVE_LEASE_TESTS=1 with verified Parakeet assets installed")
        let modelStore = ModelStore()
        let descriptor = ModelCatalog.parakeetTdtV3
        let report = await modelStore.verify(descriptor)
        try XCTSkipUnless(report.isComplete, "the pinned model must already be installed; never download in this test")
        let directory = await modelStore.directory(for: descriptor)
        let engine = try await ParakeetEngine.load(fromVerifiedDirectory: directory)

        let suite = "live-engine-lease-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = try AppServices(arguments: ["portavoz-app", "-use-temp-store"], defaults: defaults)
        let load = try XCTUnwrap(services.modelResidencyLedger.beginLoad(.liveSpeech))
        XCTAssertTrue(services.modelResidencyLedger.finishLoad(load, measuredFootprintBytes: nil))
        services.transcriber = engine

        let recording = try XCTUnwrap(services.acquireResidentLiveTranscriptionRuntime())
        let dictation = try await DictationSessionDependencies.live(services: services).acquireRuntime()
        XCTAssertEqual(recording.engine.descriptor.id, engine.descriptor.id)
        XCTAssertEqual(dictation.engine.descriptor.id, engine.descriptor.id)
        XCTAssertEqual(services.modelResidencyLedger.record(for: .liveSpeech).activeUseCount, 2)
        XCTAssertFalse(services.releaseLiveSpeechRuntime())

        recording.finish()
        XCTAssertEqual(services.modelResidencyLedger.record(for: .liveSpeech).activeUseCount, 1)
        XCTAssertFalse(services.releaseLiveSpeechRuntime(), "dictation still owns the live model")
        dictation.finish()
        XCTAssertEqual(services.modelResidencyLedger.record(for: .liveSpeech).activeUseCount, 0)
        XCTAssertTrue(services.releaseLiveSpeechRuntime())
        XCTAssertNil(services.transcriber)
    }
}
