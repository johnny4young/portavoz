import Foundation
import Testing
@testable import portavoz_app

@Suite(.serialized)
struct UITestDefaultsTests {
    @Test
    func temporaryStoreLaunchInstallsVolatileOverrides() throws {
        let suiteName = "UITestDefaultsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
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

        #expect(defaults.bool(forKey: "globalDictationEnabled"))
        #expect(defaults.integer(forKey: "dictationMouseButton") == 4)
        #expect(
            defaults.persistentDomain(forName: suiteName)?["dictationMouseButton"] == nil)
    }

    @Test
    func ordinaryLaunchAndMalformedPayloadAreIgnored() throws {
        let suiteName = "UITestDefaultsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: suiteName)
        }

        UITestDefaults.installIfNeeded(
            arguments: ["Portavoz"],
            environment: [UITestDefaults.environmentKey: #"{"enabled":true}"#],
            defaults: defaults)
        #expect(defaults.object(forKey: "enabled") == nil)

        UITestDefaults.installIfNeeded(
            arguments: ["Portavoz", "-use-temp-store"],
            environment: [UITestDefaults.environmentKey: "not-json"],
            defaults: defaults)
        #expect(defaults.object(forKey: "enabled") == nil)
    }
}
