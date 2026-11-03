import Foundation
import XCTest

@testable import portavoz_app
@testable import TranscriptionKit

/// The real acquisition loop and residency ledger, with engines that never load weights.
@MainActor
final class ParakeetUltraRuntimeTests: XCTestCase {
    private func engine(_ checkpoint: ParakeetCheckpoint) -> ParakeetEngine {
        ParakeetEngine(
            prepareLiveManager: { _ in throw CancellationError() },
            prepareBatchManager: { _ in throw CancellationError() },
            checkpoint: checkpoint)
    }

    private func services(resident checkpoint: ParakeetCheckpoint) throws -> AppServices {
        let suite = "parakeet-ultra-runtime-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let services = try AppServices(arguments: ["portavoz-app", "-use-temp-store"], defaults: defaults)
        let ticket = try XCTUnwrap(services.modelResidencyLedger.beginLoad(.liveSpeech))
        XCTAssertTrue(services.modelResidencyLedger.finishLoad(ticket, measuredFootprintBytes: nil))
        services.transcriber = engine(checkpoint)
        return services
    }

    func testDictationBorrowsTheV3RuntimeAMeetingIsUsing() async throws {
        let services = try services(resident: .v3)
        let meeting = try XCTUnwrap(services.acquireResidentLiveSpeechRuntime())
        let dictation = try await services.acquireLiveSpeechRuntime(checkpoint: .ultra, acceptsResident: true)
        XCTAssertEqual(dictation.engine.checkpoint, .v3, "no second model loads during a meeting")
        XCTAssertEqual(services.modelResidencyLedger.record(for: .liveSpeech).activeUseCount, 2)
        XCTAssertTrue(services.finishLiveSpeechRuntime(dictation))
        XCTAssertTrue(services.finishLiveSpeechRuntime(meeting))
    }

    func testMeetingsWaitForAnUltraDictationAndNeverBorrowIt() async throws {
        let services = try services(resident: .ultra)
        XCTAssertNil(try services.acquireResidentLiveSpeechRuntime(), "recording never attaches Ultra")
        let dictation = try await services.acquireLiveSpeechRuntime(checkpoint: .ultra, acceptsResident: true)
        XCTAssertEqual(dictation.engine.checkpoint, .ultra)
        let meeting = Task { @MainActor in try await services.acquireLiveSpeechRuntime() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(services.transcriber?.checkpoint, .ultra, "an Ultra dictation in use is never swapped out")
        XCTAssertNil(services.liveSpeechRuntimeLoad, "the meeting waits instead of loading a second model")
        meeting.cancel()
        do {
            _ = try await meeting.value
            XCTFail("a cancelled wait must not acquire a runtime")
        } catch is CancellationError {}
        XCTAssertTrue(services.finishLiveSpeechRuntime(dictation))
        XCTAssertEqual(services.modelResidencyLedger.record(for: .liveSpeech).activeUseCount, 0)
    }
}
