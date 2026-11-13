import Foundation
import XCTest

@testable import portavoz_app
@testable import TranscriptionKit

/// The real acquisition path and residency ledger, with an engine that never loads weights.
@MainActor
final class LiveSpeechRuntimeSharingTests: XCTestCase {
    private func servicesWithResidentEngine() throws -> AppServices {
        let suite = "live-speech-runtime-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let services = try AppServices(arguments: ["portavoz-app", "-use-temp-store"], defaults: defaults)
        let ticket = try XCTUnwrap(services.modelResidencyLedger.beginLoad(.liveSpeech))
        XCTAssertTrue(services.modelResidencyLedger.finishLoad(ticket, measuredFootprintBytes: nil))
        services.transcriber = ParakeetEngine(
            prepareLiveManager: { _ in throw CancellationError() },
            prepareBatchManager: { _ in throw CancellationError() })
        return services
    }

    func testASecondLiveCallerSharesTheRuntimeAMeetingIsUsing() async throws {
        let services = try servicesWithResidentEngine()
        let resident = services.transcriber
        let meeting = try XCTUnwrap(services.acquireResidentLiveSpeechRuntime())
        let second = try await services.acquireLiveSpeechRuntime()
        XCTAssertTrue(second.engine === resident, "no second model loads during a meeting")
        XCTAssertNil(services.liveSpeechRuntimeLoad)
        XCTAssertEqual(services.modelResidencyLedger.record(for: .liveSpeech).activeUseCount, 2)
        XCTAssertFalse(services.releaseLiveSpeechRuntime(), "an in-use runtime is never released")
        XCTAssertTrue(services.finishLiveSpeechRuntime(second))
        XCTAssertTrue(services.finishLiveSpeechRuntime(meeting))
        XCTAssertEqual(services.modelResidencyLedger.record(for: .liveSpeech).activeUseCount, 0)
    }

    func testTheLiveLaneOfAParakeetRuntimeIsParakeet() async throws {
        let services = try servicesWithResidentEngine()
        let runtime = try XCTUnwrap(services.acquireResidentLiveTranscriptionRuntime())
        XCTAssertEqual(runtime.lane, .parakeet)
        runtime.finish()
        XCTAssertEqual(services.modelResidencyLedger.record(for: .liveSpeech).activeUseCount, 0)
    }
}
