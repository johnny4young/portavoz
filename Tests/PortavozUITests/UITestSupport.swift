import AppKit
import XCTest

/// Shared base for Portavoz UI journeys.
///
/// This type deliberately installs no interruption monitor. System-owned
/// privacy or authentication prompts require a user's decision; the read-only
/// host preflight reports them instead of allowing tests to answer them.
class PortavozUITestCase: XCTestCase {}

/// Evaluate an explicit state predicate without XCTest's one-second polling
/// floor. The run loop stays live between probes, so asynchronous app and
/// accessibility updates continue to arrive; there is no blind fixed delay.
@MainActor
@discardableResult
func waitForUITestCondition(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.05,
    _ condition: () -> Bool
) -> Bool {
    if condition() { return true }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let nextProbe = min(deadline, Date().addingTimeInterval(pollInterval))
        _ = RunLoop.current.run(mode: .default, before: nextProbe)
        if condition() { return true }
    }
    return condition()
}

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

enum AutomationEntityUITestRoute: String {
    case meeting
    case person
    case commitment
}

extension XCUIApplication {
    @MainActor
    static func portavoz(
        seedDemo: Bool = false,
        seedShowcase: Bool = false,
        seedScale: Bool = false,
        scaleSegmentCount: Int? = nil,
        scaleAutoSummaryUpdate: Bool = false,
        seedLatestRecipe: Bool = false,
        seedBrief: Bool = false,
        seedRefineRunning: Bool = false,
        seedJustRecorded: Bool = false,
        seedRecovery: Bool = false,
        seedProcessing: Bool = false,
        seedProcessingFailure: Bool = false,
        seedWithoutSummary: Bool = false,
        seedStaleDerived: Bool = false,
        seedCommitmentInbox: Bool = false,
        seedCommitmentRadar: Bool = false,
        seedAskMemory: Bool = false,
        seedAskTopicMemory: Bool = false,
        simulateSequoiaCapabilities: Bool = false,
        simulateRecordingStartFailure: Bool = false,
        simulateSystemCaptureStall: Bool = false,
        simulateSystemAudioClipping: Bool = false,
        simulateLiveTranscriptionAttach: Bool = false,
        simulateLiveTranscriptBrowsing: Bool = false,
        simulateProactiveAssist: Bool = false,
        simulateInterviewAssist: Bool = false,
        simulateSemanticAssetsMissing: Bool = false,
        simulateSkillEffectFailureOnce: Bool = false,
        simulateApuntadorRefreshSuccess: Bool = false,
        simulateAppIntent: Bool = false,
        simulateStopAppIntent: Bool = false,
        simulateAppEntityRoute: AutomationEntityUITestRoute? = nil,
        showMenuBarContent: Bool = false,
        openSettings: Bool = false,
        showOnboarding: Bool = false,
        includeWebFixture: Bool = false,
        launchLocale: String? = UITestLocale.environmentLocale
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-NSTreatUnknownArgumentsAsOpen", "NO", "-ApplePersistenceIgnoreState", "YES", "-use-temp-store", "-reset-app-language"]
        if seedDemo {
            app.launchArguments.append("-seed-demo")
            app.launchEnvironment["PORTAVOZ_UI_TEST_SEED_READY_PATH"] =
                NSTemporaryDirectory() + "portavoz-seed-ready-\(UUID().uuidString)"
        }
        if seedShowcase {
            app.launchArguments.append("-seed-showcase")
            app.launchEnvironment["PORTAVOZ_UI_TEST_SEED_READY_PATH"] =
                NSTemporaryDirectory() + "portavoz-showcase-ready-\(UUID().uuidString)"
        }
        if seedScale { app.launchArguments.append("-seed-scale") }
        if let scaleSegmentCount {
            app.launchArguments += ["-scale-segments", String(scaleSegmentCount)]
        }
        if scaleAutoSummaryUpdate { app.launchArguments.append("-scale-auto-summary-update") }
        if seedLatestRecipe { app.launchArguments.append("-seed-latest-recipe") }
        if seedBrief { app.launchArguments.append("-seed-brief") }
        if seedRefineRunning { app.launchArguments.append("-seed-refine-running") }
        if seedJustRecorded { app.launchArguments.append("-seed-just-recorded") }
        if seedRecovery {
            app.launchArguments.append("-seed-recovery")
            app.launchEnvironment["PORTAVOZ_UI_TEST_SEED_READY_PATH"] =
                NSTemporaryDirectory() + "portavoz-recovery-ready-\(UUID().uuidString)"
        }
        if seedProcessing { app.launchArguments.append("-seed-processing") }
        if seedProcessingFailure { app.launchArguments.append("-seed-processing-failure") }
        if seedWithoutSummary { app.launchArguments.append("-seed-without-summary") }
        if seedStaleDerived { app.launchArguments.append("-seed-stale-derived") }
        if seedCommitmentInbox { app.launchArguments.append("-seed-commitment-inbox") }
        if seedCommitmentRadar { app.launchArguments.append("-seed-commitment-radar") }
        if seedAskMemory { app.launchArguments.append("-seed-ask-memory") }
        if seedAskTopicMemory { app.launchArguments.append("-seed-ask-topic-memory") }
        if simulateSequoiaCapabilities {
            app.launchArguments.append("-simulate-sequoia-capabilities")
        }
        if simulateRecordingStartFailure {
            app.launchArguments.append("-simulate-recording-start-failure")
        }
        if simulateSystemCaptureStall {
            app.launchArguments.append("-simulate-system-capture-stall")
        }
        if simulateSystemAudioClipping {
            app.launchArguments.append("-simulate-system-audio-clipping")
        }
        if simulateLiveTranscriptionAttach {
            app.launchArguments.append("-simulate-live-transcription-attach")
            let signalID = UUID().uuidString
            app.launchEnvironment["PORTAVOZ_UI_TEST_ATTACH_PREPARING_PATH"] =
                NSTemporaryDirectory() + "portavoz-attach-preparing-\(signalID)"
            app.launchEnvironment["PORTAVOZ_UI_TEST_ATTACH_CONTINUE_PATH"] =
                NSTemporaryDirectory() + "portavoz-attach-continue-\(signalID)"
        }
        if simulateLiveTranscriptBrowsing {
            app.launchArguments.append("-simulate-live-transcript-browsing")
            let signalID = UUID().uuidString
            app.launchEnvironment["PORTAVOZ_UI_TEST_LIVE_FRONTIER_PATH"] =
                NSTemporaryDirectory() + "portavoz-live-frontier-\(signalID)"
            app.launchEnvironment["PORTAVOZ_UI_TEST_LIVE_RESUME_PATH"] =
                NSTemporaryDirectory() + "portavoz-live-resume-\(signalID)"
            app.launchEnvironment["PORTAVOZ_UI_TEST_LIVE_COMPLETE_PATH"] =
                NSTemporaryDirectory() + "portavoz-live-complete-\(signalID)"
        }
        if simulateProactiveAssist {
            app.launchArguments.append("-simulate-proactive-assist")
        }
        if simulateInterviewAssist {
            app.launchArguments.append("-simulate-interview-assist")
        }
        if simulateSemanticAssetsMissing {
            app.launchArguments.append("-simulate-semantic-assets-missing")
        }
        if simulateSkillEffectFailureOnce {
            app.launchArguments.append("-simulate-skill-effect-failure-once")
        }
        if simulateApuntadorRefreshSuccess {
            app.launchArguments.append("-simulate-apuntador-refresh-success")
        }
        if simulateAppIntent {
            app.launchArguments.append("-simulate-app-intent")
        }
        if simulateStopAppIntent {
            app.launchArguments.append("-simulate-stop-app-intent")
        }
        appendAppEntityRoute(simulateAppEntityRoute, to: app)
        if showMenuBarContent {
            app.launchArguments.append("-show-menu-bar-content")
        }
        if openSettings { app.launchArguments.append("-portavoz-open-settings") }
        if showOnboarding { app.launchArguments.append("-show-onboarding") }
        // AppKit writes ignored-restoration state into TMPDIR. Give every
        // process a private root so back-to-back launches cannot race the same
        // bundle-scoped savedState directory after a preceding termination.
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
        if includeWebFixture,
           let webFixture = ProcessInfo.processInfo.environment[
            "PORTAVOZ_UI_WEB_FIXTURE_PAYLOAD"],
           !webFixture.isEmpty {
            app.launchEnvironment["PORTAVOZ_UI_WEB_FIXTURE_PAYLOAD"] =
                webFixture
        }
        UITestLocale.apply(launchLocale, to: app)
        return app
    }

    @MainActor
    private static func appendAppEntityRoute(
        _ route: AutomationEntityUITestRoute?,
        to app: XCUIApplication
    ) {
        guard let route else { return }
        app.launchArguments += ["-simulate-app-entity-route", route.rawValue]
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
        XCTAssertTrue(
            waitForPortavozProcessExit(),
            "the preceding Portavoz process must leave the running-app inventory")
        launch()
        XCTAssertTrue(
            wait(for: .runningForeground, timeout: 15),
            "Portavoz must remain in the foreground after launch")
        activate()
        let mainWindow = windows["main-AppWindow-1"]
        XCTAssertTrue(
            mainWindow.waitForExistenceFast(timeout: 15),
            "the disposable main window must exist before UI assertions")
        XCTAssertTrue(
            mainWindow.waitForStableFrame(timeout: 5, stableFor: 0.1),
            "the disposable main window must finish its first-frame placement")
        if shouldOpenSettings {
            XCTAssertTrue(
                buttons["library-new-recording-button"]
                    .waitForStableFrame(timeout: 20),
                "the library must finish its cold-start layout before opening Settings")
            XCTAssertTrue(
                openSettingsWindow(),
                "the Settings command must open the settings window")
            let general = control(withIdentifier: "settings-category-general")
            XCTAssertTrue(
                general.waitForStableFrame(timeout: 10),
                "the disposable Settings window must finish placement")
            XCTAssertGreaterThanOrEqual(
                general.frame.minX,
                0,
                "temporary Settings must stay on AppKit's zero screen")
            XCTAssertGreaterThanOrEqual(
                general.frame.minY,
                0,
                "temporary Settings must stay inside the zero screen's visible frame")
        }
    }

    /// XCUITest can report `.notRunning` before LaunchServices removes the
    /// process from its inventory. Observe the real host state instead of
    /// sleeping on every launch; an already-clear host returns immediately.
    @MainActor
    private func waitForPortavozProcessExit(timeout: TimeInterval = 10) -> Bool {
        waitForUITestCondition(timeout: timeout) {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "app.portavoz.mac.uitest-host"
            ).isEmpty
        }
    }

    @MainActor
    func control(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier]
    }

    /// Reassert Portavoz as the foreground app before a critical interaction.
    ///
    /// Full-suite runs can overlap with unrelated apps that legitimately raise
    /// their own windows. XCUITest then reports Portavoz controls as not
    /// hittable even though their layout is valid. Reactivating the app is
    /// non-destructive and avoids teaching the harness to dismiss or terminate
    /// arbitrary third-party windows.
    @MainActor
    func prepareForInteraction(timeout: TimeInterval = 10) -> Bool {
        activate()
        return wait(for: .runningForeground, timeout: timeout)
    }

    /// Ensures the production Settings window is open without dismissing or
    /// terminating an unrelated foreground app. A single bounded retry covers
    /// the case where macOS consumes Command-comma only to reactivate Portavoz.
    @MainActor
    func openSettingsWindow(timeout: TimeInterval = 10) -> Bool {
        let general = control(withIdentifier: "settings-category-general")
        if general.exists {
            return prepareForInteraction(timeout: timeout)
        }

        for attempt in 0..<2 {
            guard prepareForInteraction(timeout: timeout) else { continue }
            typeKey(",", modifierFlags: .command)
            if general.waitForExistenceFast(timeout: attempt == 0 ? 2 : timeout) {
                return true
            }
        }
        return false
    }

    /// Selects a Settings category and proves its exact destination appeared.
    /// The first missed interaction is retried without recording a premature
    /// assertion failure; a persistent product failure still fails the caller.
    @MainActor
    func openSettingsCategory(
        _ identifier: String,
        revealing expectedControlIdentifier: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        let category = control(withIdentifier: identifier)
        let expectedControl = control(withIdentifier: expectedControlIdentifier)
        for attempt in 0..<2 {
            guard prepareForInteraction(timeout: timeout) else { continue }
            guard category.waitForStableFrame(timeout: timeout) else { continue }
            category.click()
            if expectedControl.waitForExistenceFast(timeout: attempt == 0 ? 2 : 5) {
                return true
            }
        }
        return false
    }

    /// Seeded-library launches mutate the sidebar once after the first frame.
    /// Waiting for the row to become hittable keeps a later toolbar click from
    /// resolving against the pre-seed accessibility snapshot.
    @MainActor
    func waitForSeededLibraryToSettle(timeout: TimeInterval = 45) -> Bool {
        guard waitForSeedFixtureReady(timeout: timeout) else { return false }
        guard prepareForInteraction(timeout: timeout) else { return false }

        let meeting = descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        guard meeting.waitForExistenceFast(timeout: timeout) else { return false }
        return waitForUITestCondition(timeout: timeout) { meeting.isHittable }
    }

    /// Waits only for the disposable seed transaction. Menu-bar UI tests mount
    /// the production resident content instead of Library, so they cannot use
    /// a meeting-row accessibility element as their readiness signal.
    @MainActor
    func waitForSeedFixtureReady(timeout: TimeInterval = 45) -> Bool {
        guard let readyPath = launchEnvironment["PORTAVOZ_UI_TEST_SEED_READY_PATH"] else {
            return false
        }
        guard waitForFile(atPath: readyPath, timeout: timeout) else { return false }
        try? FileManager.default.removeItem(atPath: readyPath)
        return true
    }

    @MainActor
    func waitForLiveTranscriptionAttachPreparing(timeout: TimeInterval = 20) -> Bool {
        waitForUITestSignal(
            environmentKey: "PORTAVOZ_UI_TEST_ATTACH_PREPARING_PATH",
            timeout: timeout)
    }

    @MainActor
    func continueLiveTranscriptionAttachFixture() -> Bool {
        markUITestSignal(environmentKey: "PORTAVOZ_UI_TEST_ATTACH_CONTINUE_PATH")
    }

    @MainActor
    func waitForLiveTranscriptFrontier(timeout: TimeInterval = 20) -> Bool {
        waitForUITestSignal(
            environmentKey: "PORTAVOZ_UI_TEST_LIVE_FRONTIER_PATH",
            timeout: timeout)
    }

    @MainActor
    func resumeLiveTranscriptFixture() -> Bool {
        markUITestSignal(environmentKey: "PORTAVOZ_UI_TEST_LIVE_RESUME_PATH")
    }

    @MainActor
    func waitForLiveTranscriptFixtureToFinish(timeout: TimeInterval = 20) -> Bool {
        waitForUITestSignal(
            environmentKey: "PORTAVOZ_UI_TEST_LIVE_COMPLETE_PATH",
            timeout: timeout)
    }

    private func markUITestSignal(environmentKey: String) -> Bool {
        guard let path = launchEnvironment[environmentKey] else { return false }
        return FileManager.default.createFile(atPath: path, contents: Data())
    }

    private func waitForUITestSignal(
        environmentKey: String,
        timeout: TimeInterval
    ) -> Bool {
        guard let path = launchEnvironment[environmentKey] else { return false }
        return waitForFile(atPath: path, timeout: timeout)
    }

    private func waitForFile(
        atPath path: String,
        timeout: TimeInterval
    ) -> Bool {
        waitForUITestCondition(timeout: timeout, pollInterval: 0.02) {
            FileManager.default.fileExists(atPath: path)
        }
    }
}

extension XCUIElement {
    /// Avoid XCTest's one-second first poll when the element is already in the
    /// accessibility tree. Asynchronous states retain the same bounded wait.
    @MainActor
    func waitForExistenceFast(timeout: TimeInterval) -> Bool {
        waitForUITestCondition(timeout: timeout) { self.exists }
    }

    @MainActor
    func waitForValueChange(
        from initialValue: String,
        timeout: TimeInterval
    ) -> Bool {
        let changed = {
            self.exists && String(describing: self.value) != initialValue
        }
        return waitForUITestCondition(timeout: timeout, changed)
    }

    @MainActor
    func waitForSelection(timeout: TimeInterval) -> Bool {
        waitForUITestCondition(timeout: timeout) {
            self.exists && self.isSelected
        }
    }

    @MainActor
    func waitForDisappearance(timeout: TimeInterval) -> Bool {
        waitForUITestCondition(timeout: timeout) { !self.exists }
    }

    /// Prove that a control stays absent for a bounded observation window.
    /// Unlike an inverted XCTest predicate, this uses the same short,
    /// run-loop-driven probes as positive state waits.
    @MainActor
    func remainsAbsent(for duration: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            if exists { return false }
            let nextProbe = min(deadline, Date().addingTimeInterval(0.05))
            _ = RunLoop.current.run(mode: .default, before: nextProbe)
        }
        return !exists
    }

    @MainActor
    func waitForHittable(timeout: TimeInterval) -> Bool {
        waitForUITestCondition(timeout: timeout) { self.isHittable }
    }

    @MainActor
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        waitForUITestCondition(timeout: timeout) {
            self.exists && self.isEnabled
        }
    }

    @MainActor
    func waitForValue(_ expectedValue: String, timeout: TimeInterval) -> Bool {
        waitForUITestCondition(timeout: timeout) {
            self.value as? String == expectedValue
        }
    }

    @MainActor
    func waitForValueOtherThan(_ value: String, timeout: TimeInterval) -> Bool {
        waitForUITestCondition(timeout: timeout) {
            self.exists && self.value as? String != value
        }
    }

    @MainActor
    func waitForLabelContaining(_ text: String, timeout: TimeInterval) -> Bool {
        waitForUITestCondition(timeout: timeout) {
            self.label.contains(text)
        }
    }

    @MainActor
    func waitForLabelNotContaining(_ text: String, timeout: TimeInterval) -> Bool {
        waitForUITestCondition(timeout: timeout) {
            self.exists && !self.label.contains(text)
        }
    }

    @MainActor
    func waitForLabelOrValue(_ text: String, timeout: TimeInterval) -> Bool {
        waitForUITestCondition(timeout: timeout) {
            self.exists && (self.label == text || self.value as? String == text)
        }
    }

    /// Localized and asynchronously populated SwiftUI content can expose a
    /// hittable accessibility element one frame before its final layout.
    /// Wait for the hit target itself to stop moving so `click()` cannot use a
    /// stale activation point and silently miss the intended control.
    @MainActor
    func waitForStableFrame(
        timeout: TimeInterval = 5,
        stableFor stableInterval: TimeInterval = 0.25
    ) -> Bool {
        guard waitForExistenceFast(timeout: timeout) else { return false }
        var previousFrame: CGRect?
        var stableSince: Date?
        return waitForUITestCondition(timeout: timeout) {
            let currentFrame = self.frame
            if self.isHittable, currentFrame == previousFrame {
                if let stableSince {
                    return Date().timeIntervalSince(stableSince) >= stableInterval
                }
                stableSince = Date()
            } else {
                previousFrame = currentFrame
                stableSince = nil
            }
            return false
        }
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
