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
}
