import Foundation
import ModelStoreKit
import TranscriptionKit
import XCTest

@testable import portavoz_app

@MainActor
final class ParakeetUltraSelectionTests: XCTestCase {
    func testOneResidentCheckpointIsBorrowedSwappedOrAwaited() async {
        typealias Plan = LiveSpeechCheckpointPlan
        func plan(_ requested: ParakeetCheckpoint, resident: ParakeetCheckpoint?, inUse: Bool = false,
                  loading: Bool = false, accepts: Bool = false) -> Plan {
            Plan(requested: requested, resident: resident, residentInUse: inUse,
                 loading: loading, acceptsResident: accepts)
        }
        XCTAssertEqual(plan(.ultra, resident: nil), .load)
        XCTAssertEqual(plan(.ultra, resident: .ultra, inUse: true), .useResident)
        XCTAssertEqual(plan(.ultra, resident: .v3), .swap, "An idle v3 gives way to the selected checkpoint")
        XCTAssertEqual(plan(.ultra, resident: .v3, inUse: true, accepts: true), .useResident,
                       "Dictation during a meeting borrows v3 instead of loading a second model")
        XCTAssertEqual(plan(.v3, resident: .ultra, inUse: true), .waitForIdle,
                       "A meeting never runs on the dictation-only checkpoint")
        XCTAssertEqual(plan(.v3, resident: .ultra), .swap)
        XCTAssertEqual(plan(.v3, resident: nil, loading: true), .awaitLoad)
    }

    func testMeetingsNeverSelectUltraAndDictationFallsBackUntilItIsInstalled() async throws {
        let suite = "parakeet-ultra-selection-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(LiveSpeechSelection.parakeetUltra.rawValue, forKey: LiveSpeechSelection.meetingKey)
        defaults.set(LiveSpeechSelection.parakeetUltra.rawValue, forKey: LiveSpeechSelection.dictationKey)
        XCTAssertEqual(LiveSpeechSelection.meeting(defaults: defaults), .parakeet)
        XCTAssertEqual(LiveSpeechSelection.dictation(defaults: defaults), .parakeetUltra)

        let services = try AppServices(arguments: ["-use-temp-store"], environment: [:], defaults: defaults)
        let checkpoint = await services.dictationCheckpoint()
        XCTAssertEqual(checkpoint, .v3, "A selected but missing Ultra never blocks or downloads")
        await services.installParakeetUltraModel()
        XCTAssertEqual(services.parakeetUltraModel, .missing, "The disposable composition never downloads")
        XCTAssertNotEqual(ModelCatalog.recommended(for: .liveTranscription)?.id, ModelCatalog.parakeetUltra.id,
                          "Ultra is never the recommended live model")
    }

    func testCancellingAnUltraDownloadStopsItAndOffersItAgain() async throws {
        let suite = "parakeet-ultra-cancel-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = try AppServices(arguments: ["-use-temp-store"], environment: [:], defaults: defaults)
        let download = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        services.parakeetUltraDownload = download
        services.parakeetUltraModel = .downloading(42)
        services.cancelParakeetUltraDownload()
        XCTAssertTrue(download.isCancelled, "the in-flight download is cancelled")
        XCTAssertNil(services.parakeetUltraDownload)
        XCTAssertEqual(services.parakeetUltraModel, .missing, "Download is offered again")
        services.startParakeetUltraDownload()
        let settled = await awaitCondition { services.parakeetUltraDownload == nil }
        XCTAssertTrue(settled)
        XCTAssertEqual(services.parakeetUltraModel, .missing, "the disposable composition never downloads")
    }

    func testACancelledDownloadLeavesANewerDownloadInCharge() async throws {
        let suite = "parakeet-ultra-restart-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = try AppServices(arguments: ["-use-temp-store"], environment: [:], defaults: defaults)
        services.startParakeetUltraDownload()
        let cancelled = try XCTUnwrap(services.parakeetUltraDownload)
        services.cancelParakeetUltraDownload()
        let newer = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        defer { newer.cancel() }
        services.parakeetUltraDownload = newer
        await cancelled.value
        XCTAssertEqual(services.parakeetUltraDownload, newer, "the cancelled task must not clear the newer handle")
    }

    private func awaitCondition(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }
}
