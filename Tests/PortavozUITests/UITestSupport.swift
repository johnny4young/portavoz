import XCTest

enum UITestLocale {
    static var environmentLocale: String? {
        let value = ProcessInfo.processInfo.environment["PORTAVOZ_UI_TEST_LOCALE"]
        return ["en", "es"].contains(value) ? value : nil
    }

    @MainActor
    static func apply(_ locale: String?, to app: XCUIApplication) {
        guard let locale else { return }
        app.launchArguments += [
            "-AppleLanguages", "(\(locale))",
            "-AppleLocale", locale == "es" ? "es_ES" : "en_US"
        ]
    }
}

extension XCUIApplication {
    @MainActor
    static func portavoz(
        seedDemo: Bool = false,
        seedRecovery: Bool = false,
        openSettings: Bool = false,
        showOnboarding: Bool = false,
        launchLocale: String? = UITestLocale.environmentLocale
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-NSTreatUnknownArgumentsAsOpen", "NO", "-ApplePersistenceIgnoreState", "YES", "-use-temp-store", "-reset-app-language"]
        if seedDemo { app.launchArguments.append("-seed-demo") }
        if seedRecovery { app.launchArguments.append("-seed-recovery") }
        if openSettings { app.launchArguments.append("-portavoz-open-settings") }
        if showOnboarding { app.launchArguments.append("-show-onboarding") }
        // Every UI launch gets an isolated audio root by default. Individual
        // tests may replace it with an explicit scratch copy of real audio.
        app.launchEnvironment["PORTAVOZ_AUDIO_ROOT"] =
            NSTemporaryDirectory() + "portavoz-uitest-\(UUID().uuidString)"
        UITestLocale.apply(launchLocale, to: app)
        return app
    }

    @MainActor
    func launchPortavoz() {
        launch()
        activate()
    }

    @MainActor
    func control(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier]
    }
}
