import Foundation
import XCTest
@testable import portavoz_app

final class UITestDefaultsTests: XCTestCase {
    func testTemporaryStoreLaunchInstallsVolatileOverrides() throws {
        let suiteName = "UITestDefaultsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(false, forKey: "globalDictationEnabled")
        UITestDefaults.installIfNeeded(
            arguments: ["Portavoz", "-use-temp-store"],
            environment: [
                UITestDefaults.environmentKey:
                    #"{"globalDictationEnabled":true,"dictationMouseButton":4}"#
            ],
            defaults: defaults)

        XCTAssertTrue(defaults.bool(forKey: "globalDictationEnabled"))
        XCTAssertEqual(defaults.integer(forKey: "dictationMouseButton"), 4)
        XCTAssertNil(
            defaults.persistentDomain(forName: suiteName)?["dictationMouseButton"])
    }

    func testOrdinaryLaunchAndMalformedPayloadAreIgnored() throws {
        let suiteName = "UITestDefaultsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: suiteName)
        }

        UITestDefaults.installIfNeeded(
            arguments: ["Portavoz"],
            environment: [UITestDefaults.environmentKey: #"{"enabled":true}"#],
            defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "enabled"))

        UITestDefaults.installIfNeeded(
            arguments: ["Portavoz", "-use-temp-store"],
            environment: [UITestDefaults.environmentKey: "not-json"],
            defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "enabled"))
    }
}
