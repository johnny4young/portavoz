import ApplicationKit
import Foundation
import XCTest

@testable import portavoz_app

final class ModelMemoryGuidanceTests: XCTestCase {
    func testRealProviderProbeUsesBinaryMemoryWithoutOverflowOrRoundingUp() async {
        let gib = AppModelMemoryCapacity.gibibyte
        for (bytes, expected) in [(0, 0), (8 * gib - 1, 7), (8 * gib, 8),
                                  (8 * gib + 1, 8), (16 * gib, 16), (UInt64.max, 17_179_869_183)] {
            let probe = AppLocalSummaryProviderProbe(
                appleOnDeviceAvailable: false, usesTemporaryStore: false,
                capacity: .init(bytes: bytes), freeDiskGB: { 100 }, localOllama: { .unavailable })
            let discovery = await DiscoverLocalSummaryProviders(probe: probe).execute(())
            XCTAssertEqual(discovery.profile.memoryGB, expected)
            XCTAssertEqual(discovery.recommendation.selection?.engine, expected >= 8 ? .mlx : nil)
        }
    }

    func testDisposableProbeCannotObserveHostEvenWithInjectedValues() async {
        let probe = AppLocalSummaryProviderProbe(
            appleOnDeviceAvailable: true, usesTemporaryStore: true, capacity: .init(bytes: 1),
            freeDiskGB: { XCTFail("temporary probe read host disk"); return 1 },
            localOllama: { XCTFail("temporary probe reached provider"); return .running(models: []) })
        let result = await probe.probeLocalSummaryProviders()
        XCTAssertEqual(result.memoryGB, 16)
        XCTAssertEqual(result.freeDiskGB, 100)
        XCTAssertEqual(result.ollama, .unavailable)
        XCTAssertTrue(result.appleOnDeviceAvailable)
    }

    @MainActor
    func testAdvisoryProfileNeverRewritesExplicitOrLegacySelections() async {
        let suite = "model-memory-guidance-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gib = AppModelMemoryCapacity.gibibyte
        for bytes in [0, 8 * gib - 1, 8 * gib, 8 * gib + 1, 16 * gib, UInt64.max] {
            let preferences = AppModelMemoryPreferences(defaults: defaults, physicalMemoryBytes: bytes)
            XCTAssertEqual(preferences.recommendedProfile, bytes > 0 && bytes <= 8 * gib ? .lightweight : .balanced)
            XCTAssertEqual(preferences.profile, .balanced)
            XCTAssertNil(defaults.object(forKey: AppModelMemoryPreferences.key))
            XCTAssertNil(defaults.object(forKey: "whisperCompact"))
        }
        defaults.set(false, forKey: "whisperCompact")
        defaults.set("ollama", forKey: "summaryEngine")
        let preferences = AppModelMemoryPreferences(defaults: defaults, physicalMemoryBytes: 8 * gib)
        for value: Any in ["unknown", -1, ["lightweight"]] {
            defaults.set(value, forKey: AppModelMemoryPreferences.key)
            XCTAssertEqual(preferences.profile, .balanced)
            XCTAssertEqual(defaults.object(forKey: "whisperCompact") as? Bool, false)
            XCTAssertEqual(defaults.string(forKey: "summaryEngine"), "ollama")
        }
        preferences.setProfile(.lightweight)
        XCTAssertEqual(AppModelMemoryPreferences(defaults: defaults).profile, .lightweight)
    }

    func testCatalogBoundaryRejectsNeitherUnknownMemoryNorInvalidMinimum() {
        let gib = AppModelMemoryCapacity.gibibyte
        for minimum in [-1, 0, Int.max] {
            XCTAssertFalse(AppModelMemoryCapacity(bytes: 0).isBelowCatalogRAM(minimum))
        }
        XCTAssertFalse(AppModelMemoryCapacity(bytes: 1).isBelowCatalogRAM(-1))
        XCTAssertTrue(AppModelMemoryCapacity(bytes: 8 * gib - 1).isBelowCatalogRAM(8))
        XCTAssertFalse(AppModelMemoryCapacity(bytes: 8 * gib).isBelowCatalogRAM(8))
        XCTAssertFalse(AppModelMemoryCapacity(bytes: UInt64.max).isBelowCatalogRAM(8))
    }
}
