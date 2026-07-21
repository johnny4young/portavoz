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
        seedScale: Bool = false,
        scaleAutoSummaryUpdate: Bool = false,
        seedLatestRecipe: Bool = false,
        seedBrief: Bool = false,
        seedRefineRunning: Bool = false,
        seedJustRecorded: Bool = false,
        seedRecovery: Bool = false,
        seedProcessing: Bool = false,
        seedProcessingFailure: Bool = false,
        seedWithoutSummary: Bool = false,
        simulateSequoiaCapabilities: Bool = false,
        simulateRecordingStartFailure: Bool = false,
        simulateSystemCaptureStall: Bool = false,
        openSettings: Bool = false,
        showOnboarding: Bool = false,
        launchLocale: String? = UITestLocale.environmentLocale
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-NSTreatUnknownArgumentsAsOpen", "NO", "-ApplePersistenceIgnoreState", "YES", "-use-temp-store", "-reset-app-language"]
        if seedDemo {
            app.launchArguments.append("-seed-demo")
            app.launchEnvironment["PORTAVOZ_UI_TEST_SEED_READY_PATH"] =
                NSTemporaryDirectory() + "portavoz-seed-ready-\(UUID().uuidString)"
        }
        if seedScale { app.launchArguments.append("-seed-scale") }
        if scaleAutoSummaryUpdate { app.launchArguments.append("-scale-auto-summary-update") }
        if seedLatestRecipe { app.launchArguments.append("-seed-latest-recipe") }
        if seedBrief { app.launchArguments.append("-seed-brief") }
        if seedRefineRunning { app.launchArguments.append("-seed-refine-running") }
        if seedJustRecorded { app.launchArguments.append("-seed-just-recorded") }
        if seedRecovery { app.launchArguments.append("-seed-recovery") }
        if seedProcessing { app.launchArguments.append("-seed-processing") }
        if seedProcessingFailure { app.launchArguments.append("-seed-processing-failure") }
        if seedWithoutSummary { app.launchArguments.append("-seed-without-summary") }
        if simulateSequoiaCapabilities {
            app.launchArguments.append("-simulate-sequoia-capabilities")
        }
        if simulateRecordingStartFailure {
            app.launchArguments.append("-simulate-recording-start-failure")
        }
        if simulateSystemCaptureStall {
            app.launchArguments.append("-simulate-system-capture-stall")
        }
        if openSettings { app.launchArguments.append("-portavoz-open-settings") }
        if showOnboarding { app.launchArguments.append("-show-onboarding") }
        // AppKit writes ignored-restoration state into TMPDIR. Give every
        // process a private root so back-to-back launches cannot race the same
        // app.portavoz.mac.savedState directory after a preceding termination.
        let processTempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("portavoz-uitest-process-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: processTempRoot,
            withIntermediateDirectories: true)
        app.launchEnvironment["TMPDIR"] = processTempRoot.path + "/"
        // Every UI launch gets an isolated audio root by default. Individual
        // tests may replace it with an explicit scratch copy of real audio.
        app.launchEnvironment["PORTAVOZ_AUDIO_ROOT"] =
            NSTemporaryDirectory() + "portavoz-uitest-\(UUID().uuidString)"
        UITestLocale.apply(launchLocale, to: app)
        return app
    }

    @MainActor
    func launchPortavoz() {
        let shouldOpenSettings = launchArguments.contains("-portavoz-open-settings")
        if shouldOpenSettings {
            // Exercise the production Settings command without teaching the
            // app process a test-only window lifecycle.
            launchArguments.removeAll { $0 == "-portavoz-open-settings" }
        }
        if state != .notRunning {
            terminate()
            XCTAssertTrue(
                wait(for: .notRunning, timeout: 10),
                "the preceding Portavoz process must terminate before relaunch")
        }
        // LaunchServices can report Not Running before its prior launch token
        // is fully retired. This small boundary avoids an ephemeral duplicate
        // process during fast full-suite transitions.
        Thread.sleep(forTimeInterval: 0.35)
        launch()
        XCTAssertTrue(
            wait(for: .runningForeground, timeout: 15),
            "Portavoz must remain in the foreground after launch")
        activate()
        let mainWindow = windows["main-AppWindow-1"]
        XCTAssertTrue(
            mainWindow.waitForExistence(timeout: 15),
            "the disposable main window must exist before UI assertions")
        // ContentView positions only disposable test windows. Let that
        // first-frame adjustment finish before a test caches a control.
        Thread.sleep(forTimeInterval: 0.2)
        if shouldOpenSettings {
            typeKey(",", modifierFlags: .command)
            _ = descendants(matching: .any)["settings-category-general"]
                .waitForExistence(timeout: 10)
        }
    }

    @MainActor
    func control(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier]
    }

    /// Seeded-library launches mutate the sidebar once after the first frame.
    /// Waiting for the row to become hittable keeps a later toolbar click from
    /// resolving against the pre-seed accessibility snapshot.
    @MainActor
    func waitForSeededLibraryToSettle(timeout: TimeInterval = 45) -> Bool {
        guard let readyPath = launchEnvironment["PORTAVOZ_UI_TEST_SEED_READY_PATH"] else {
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline,
              !FileManager.default.fileExists(atPath: readyPath) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard FileManager.default.fileExists(atPath: readyPath) else { return false }
        try? FileManager.default.removeItem(atPath: readyPath)

        let meeting = descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        guard meeting.waitForExistence(timeout: timeout) else { return false }
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: meeting)
        return XCTWaiter.wait(for: [hittable], timeout: timeout) == .completed
    }
}

extension XCUIElement {
    /// Localized and asynchronously populated SwiftUI content can expose a
    /// hittable accessibility element one frame before its final layout.
    /// Wait for the hit target itself to stop moving so `click()` cannot use a
    /// stale activation point and silently miss the intended control.
    @MainActor
    func waitForStableFrame(
        timeout: TimeInterval = 5,
        stableFor stableInterval: TimeInterval = 0.25
    ) -> Bool {
        guard waitForExistence(timeout: timeout) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        var previousFrame: CGRect?
        var stableSince: Date?

        while Date() < deadline {
            let currentFrame = frame
            if isHittable, currentFrame == previousFrame {
                if let stableSince,
                   Date().timeIntervalSince(stableSince) >= stableInterval {
                    return true
                }
                if stableSince == nil { stableSince = Date() }
            } else {
                previousFrame = currentFrame
                stableSince = nil
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
}

extension XCTestCase {
    @MainActor
    func attachScreenshot(of app: XCUIApplication, named name: String) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists, "the app window must exist before capturing evidence")
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func attachElementScreenshot(of element: XCUIElement, named name: String) {
        XCTAssertTrue(element.exists, "the app element must exist before capturing evidence")
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
