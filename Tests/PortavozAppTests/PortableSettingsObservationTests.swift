import ApplicationKit
import Foundation
import XCTest

@testable import portavoz_app

@MainActor
final class PortableSettingsObservationTests: XCTestCase {
    func testAudioCategoryKeepsShortcutNeutralLocalizationKey() async {
        XCTAssertEqual(SettingsCategory.audio.subtitleKey, "Microphone · call-safe capture")
    }

    func testTemporaryImportNotifiesMountedPreferenceObservers() async throws {
        try await verifyNotification(temporary: true)
    }

    func testPersistentImportSupersedesAnOverrideBeforeNotifyingObservers() async throws {
        try await verifyNotification(temporary: false)
    }

    private func verifyNotification(temporary: Bool) async throws {
        let suite = "settings-observation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.setVolatileDomain(["titleTemplate": "{date}"], forName: UserDefaults.argumentDomain)
        let observed = expectation(description: "observer receives the approved effective value")
        observed.assertForOverFulfill = false
        let observation = defaults.observe(\.titleTemplate, options: [.new]) { _, change in
            if let value = change.newValue, value == "{title}" { observed.fulfill() }
        }
        defer { observation.invalidate() }
        let store = AppPortableSettingsStore(defaults: defaults, temporary: temporary)
        let file = try PortableSettingsTransfer.export([.titleTemplate: .text("{title}")])
        let review = try PortableSettingsTransfer.review(file, current: store.snapshot())
        try store.apply(review, captureActive: false)
        XCTAssertEqual(try store.snapshot()[.titleTemplate], .text("{title}"))
        await fulfillment(of: [observed], timeout: 1)
    }
}

private extension UserDefaults {
    @objc dynamic var titleTemplate: String? { string(forKey: "titleTemplate") }
}
