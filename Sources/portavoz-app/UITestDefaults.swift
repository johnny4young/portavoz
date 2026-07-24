import Foundation

/// Per-launch preference overrides for the disposable XCUITest process.
///
/// `-use-temp-store` isolates the meeting database, but the app still runs
/// under its production bundle identifier and therefore sees the user's real
/// `UserDefaults`. Tests pass a JSON object through the environment; those
/// values are merged into `NSArgumentDomain`, the highest-priority volatile
/// domain, before app services read preferences. Nothing is persisted.
enum UITestDefaults {
    static let environmentKey = "PORTAVOZ_UI_TEST_DEFAULTS"

    static func installIfNeeded(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        guard arguments.contains("-use-temp-store"),
            let raw = environment[environmentKey],
            let data = raw.data(using: .utf8),
            let overrides = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return }

        let argumentDomain = UserDefaults.argumentDomain
        var values = defaults.volatileDomain(forName: argumentDomain)
        values.merge(overrides) { _, override in override }
        defaults.setVolatileDomain(values, forName: argumentDomain)
    }
}
