import Foundation
import ModelStoreKit
import XCTest

@testable import portavoz_app

@MainActor
final class SpeechModelPreferenceTests: XCTestCase {
    func testExplicitRefineModelChoiceReachesTheProductionDescriptorResolver() async {
        let defaults = UserDefaults(suiteName: "speech-model-preferences-\(UUID().uuidString)")!
        for compact in [false, true, false] {
            defaults.setVolatileDomain(["whisperCompact": compact], forName: UserDefaults.argumentDomain)
            let selected = AppServices.preferredWhisperDescriptor(defaults: defaults)
            XCTAssertEqual(selected.id, compact ? ModelCatalog.whisperLargeV3_626MB.id : ModelCatalog.whisperLargeV3Turbo.id)
            XCTAssertEqual(defaults.object(forKey: "whisperCompact") as? Bool, compact)
        }
    }

    func testLegacyMissingAndCorruptPreferenceAreNotRewrittenByResolution() async {
        let defaults = UserDefaults(suiteName: "speech-model-preferences-\(UUID().uuidString)")!
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        XCTAssertEqual(AppServices.preferredWhisperDescriptor(defaults: defaults).id, ModelCatalog.whisperLargeV3Turbo.id)
        XCTAssertNil(defaults.object(forKey: "whisperCompact"))
        for value: Any in ["invalid", -1, ["compact"]] {
            defaults.setVolatileDomain(["whisperCompact": value], forName: UserDefaults.argumentDomain)
            let before = defaults.volatileDomain(forName: UserDefaults.argumentDomain) as NSDictionary
            let legacyChoice = defaults.bool(forKey: "whisperCompact")
            XCTAssertEqual(AppServices.preferredWhisperDescriptor(defaults: defaults).id,
                           legacyChoice ? ModelCatalog.whisperLargeV3_626MB.id : ModelCatalog.whisperLargeV3Turbo.id)
            XCTAssertEqual(defaults.volatileDomain(forName: UserDefaults.argumentDomain) as NSDictionary, before)
        }
    }
}
