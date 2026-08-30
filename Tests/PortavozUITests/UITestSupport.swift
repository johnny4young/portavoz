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
        // `run(mode:before:)` may return after any handled source, which turns
        // a requested polling interval into an unbounded AX-query loop. Keep
        // servicing the default run loop until the actual probe boundary.
        RunLoop.current.run(until: nextProbe)
        if condition() { return true }
    }
    return false
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

private let notificationCenterAlertOverride =
    "PORTAVOZ_UI_TEST_ALLOW_NOTIFICATION_CENTER_ALERTS"

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
        seedBackgroundWork: Bool = false,
        enableBackgroundWorkFixture: Bool = false,
        simulateSequoiaCapabilities: Bool = false,
        simulateRecordingStartFailure: Bool = false,
        simulateSystemCaptureStall: Bool = false,
        simulateSystemAudioClipping: Bool = false,
        simulateLiveTranscriptionAttach: Bool = false,
        simulateLiveTranscriptBrowsing: Bool = false,
        simulateLiveApuntador: Bool = false,
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
        if seedScale {
            app.launchArguments.append("-seed-scale")
            app.launchEnvironment["PORTAVOZ_UI_TEST_SEED_READY_PATH"] =
                NSTemporaryDirectory() + "portavoz-scale-ready-\(UUID().uuidString)"
        }
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
        if seedBackgroundWork { app.launchArguments.append("-seed-background-work") }
        if enableBackgroundWorkFixture {
            app.launchArguments.append("-enable-background-work-fixture")
        }
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
        if simulateLiveApuntador {
            app.launchArguments.append("-simulate-live-apuntador")
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
        // The host preflight accepts this exact value only after a local
        // operator has opted into the category-scoped D432 override. Forward
        // that decision to the disposable app process so its test windows can
        // stay above the accepted Notification Center modal without reading,
        // dismissing, or answering it. CI never sets this value.
        if ProcessInfo.processInfo.environment[
            notificationCenterAlertOverride] == "true" {
            app.launchEnvironment[notificationCenterAlertOverride] = "true"
        }
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
            mainWindow.waitForHittable(timeout: 15),
            "the disposable main window must be actionable before UI assertions")
        if shouldOpenSettings {
            XCTAssertTrue(
                buttons["library-new-recording-button"]
                    .waitForStableFrame(timeout: 20),
                "the library must finish its cold-start layout before opening Settings")
            XCTAssertTrue(
                openSettingsWindow(),
                "the Settings command must open the settings window")
            let general = control(withIdentifier: "settings-category-general")
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
            guard prepareForInteraction(timeout: timeout) else { return false }
            return general.waitForStableFrame(
                timeout: timeout,
                stableFor: 0.1)
        }

        for attempt in 0..<2 {
            guard prepareForInteraction(timeout: timeout) else { continue }
            typeKey(",", modifierFlags: .command)
            if general.waitForStableFrame(
                timeout: attempt == 0 ? 2 : timeout,
                stableFor: 0.1
            ) {
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
        let categoryList = control(withIdentifier: "settings-category-list")
        let expectedControl = control(withIdentifier: expectedControlIdentifier)
        for attempt in 0..<2 {
            guard prepareForInteraction(timeout: timeout) else { continue }
            bringSettingsCategoryIntoView(category, inside: categoryList)
            guard category.waitForHittable(timeout: timeout) else { continue }
            category.click()
            if expectedControl.waitForExistenceFast(timeout: attempt == 0 ? 2 : 5) {
                return true
            }
        }
        return false
    }

    /// SwiftUI can report a clipped sidebar button as hittable even when its
    /// synthesized click lands outside the scroll viewport. Bring the whole
    /// row into the identified viewport before clicking; this is required when
    /// localized two-line labels make the category list taller than the window.
    @MainActor
    private func bringSettingsCategoryIntoView(
        _ category: XCUIElement,
        inside categoryList: XCUIElement
    ) {
        guard categoryList.exists, category.exists else { return }

        for _ in 0..<3 {
            let viewport = categoryList.frame
            let row = category.frame
            guard !viewport.isEmpty, !row.isEmpty else { return }
            if row.minY >= viewport.minY && row.maxY <= viewport.maxY {
                return
            }

            let deltaY: CGFloat
            if row.maxY > viewport.maxY {
                let distance = row.maxY - viewport.maxY + 12
                deltaY = -min(max(distance, 120), 600)
            } else if row.minY < viewport.minY {
                let distance = viewport.minY - row.minY + 12
                deltaY = min(max(distance, 120), 600)
            } else {
                return
            }
            categoryList.scroll(byDeltaX: 0, deltaY: deltaY)
        }
    }

    /// Seeded-library launches mutate the sidebar once after the first frame.
    /// Waiting for the row to become hittable keeps a later toolbar click from
    /// resolving against the pre-seed accessibility snapshot.
    @MainActor
    func waitForSeededLibraryToSettle(timeout: TimeInterval = 45) -> Bool {
        guard waitForSeedFixtureReady(timeout: timeout) else { return false }
        guard prepareForInteraction(timeout: timeout) else { return false }

        // The disposable app legitimately owns keyboard focus while XCUITest
        // launches it. A keystroke from another local process can therefore
        // land in SwiftUI's first text field and filter every seeded row before
        // the test has interacted with the app. Recover from that observable
        // state instead of retrying a launch or asking the operator to stop
        // using the machine; ordinary search journeys type only after this
        // launch boundary.
        let meeting = descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        if meeting.isHittable { return true }

        let search = textFields["library-search-field"]
        if search.exists,
           let query = search.value as? String,
           !query.isEmpty {
            search.click()
            search.typeKey("a", modifierFlags: .command)
            search.typeKey(.delete, modifierFlags: [])
            search.typeKey(.return, modifierFlags: [])
            windows["main-AppWindow-1"]
                .coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
                .click()
        }

        return meeting.waitForHittable(timeout: timeout)
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
        var candidateFrame: CGRect?
        var stableSince: Date?
        let stableProbeInterval = stableInterval > 0 ? stableInterval : 0.05
        return waitForUITestCondition(
            timeout: timeout,
            pollInterval: stableProbeInterval
        ) {
            // `isHittable` is already a safe absence/disabled/occlusion query.
            // Gate the frame read with it instead of paying a separate remote
            // `exists` query and then repeating hittability for the same edge.
            guard self.isHittable else {
                candidateFrame = nil
                stableSince = nil
                return false
            }
            let currentFrame = self.frame
            guard !currentFrame.isEmpty else {
                candidateFrame = nil
                stableSince = nil
                return false
            }
            if currentFrame != candidateFrame {
                // The preceding guard owns actionable candidate admission.
                // The next run-loop probe repeats that guard at the requested
                // stability boundary before reading the accepted frame.
                candidateFrame = currentFrame
                stableSince = Date()
                return stableInterval <= 0
            }
            guard let candidateStableSince = stableSince,
                  Date().timeIntervalSince(candidateStableSince) >= stableInterval
            else {
                return false
            }
            return true
        }
    }

    /// Reveals one control inside a bounded vertical viewport without fixed
    /// host-sized wheel gestures. Intermediate positions observe only a real
    /// frame change; the more expensive hittable/stable proof runs once the
    /// target is geometrically contained.
    @MainActor
    func revealVertically(
        in viewportElement: XCUIElement,
        maxScrolls: Int = 8,
        maximumStep: CGFloat = 48
    ) -> Bool {
        guard exists, viewportElement.exists, maximumStep > 0 else {
            return false
        }
        var viewportFrame = viewportElement.frame.insetBy(dx: 0, dy: 4)
        guard !viewportFrame.isEmpty else { return false }

        if viewportFrame.contains(frame),
           waitForStableContainedFrame(
               in: viewportElement,
               timeout: 1)
        {
            return true
        }

        for _ in 0..<maxScrolls {
            guard exists, viewportElement.exists else { return false }
            let controlFrame = frame
            let rawViewportFrame = viewportElement.frame
            viewportFrame = rawViewportFrame.insetBy(dx: 0, dy: 4)
            guard !controlFrame.isEmpty else { return false }
            guard !viewportFrame.isEmpty else { return false }

            let deltaY: CGFloat
            if controlFrame.maxY > viewportFrame.maxY {
                let distance = controlFrame.maxY - viewportFrame.maxY + 8
                deltaY = -min(max(distance, 12), maximumStep)
            } else if controlFrame.minY < viewportFrame.minY {
                let distance = viewportFrame.minY - controlFrame.minY + 8
                deltaY = min(max(distance, 12), maximumStep)
            } else {
                // Geometric containment can precede AppKit hit-test ownership
                // while a transformed transcript row is settling. Move the
                // target toward the viewport center instead of returning a
                // false terminal result; native XCUI click would otherwise do
                // this same automatic reveal after the assertion has failed.
                let inwardDelta = viewportFrame.midY - controlFrame.midY
                if abs(inwardDelta) >= 1 {
                    deltaY = min(max(inwardDelta, -maximumStep), maximumStep)
                } else {
                    deltaY = controlFrame.midY >= viewportFrame.midY ? -12 : 12
                }
            }

            viewportElement.scroll(byDeltaX: 0, deltaY: deltaY)
            let geometryChanged = waitForUITestCondition(
                timeout: 0.5,
                pollInterval: 0.02
            ) {
                let updatedFrame = self.frame
                let updatedViewportFrame = viewportElement.frame
                return (!updatedFrame.isEmpty && updatedFrame != controlFrame)
                    || (!updatedViewportFrame.isEmpty
                        && updatedViewportFrame != rawViewportFrame)
            }

            viewportFrame = viewportElement.frame.insetBy(dx: 0, dy: 4)
            if viewportFrame.contains(frame),
               waitForStableContainedFrame(
                   in: viewportElement,
                   timeout: 1)
            {
                return true
            }
            // One synthesized wheel event can be coalesced by AppKit while a
            // scroll view is settling. Treat only the total bounded attempt
            // budget as terminal evidence that the target cannot be revealed.
            if !geometryChanged { continue }
        }
        return false
    }

    /// Materializes an accessibility element that precedes a visible semantic
    /// anchor in a SwiftUI scroll view, then applies the ordinary containment
    /// proof. SwiftUI may omit a fully clipped row from AX even when its model
    /// state has already been admitted, so existence cannot be the first gate.
    @MainActor
    func revealVertically(
        in viewportElement: XCUIElement,
        above anchorElement: XCUIElement,
        maxScrolls: Int = 6,
        maximumStep: CGFloat = 48
    ) -> Bool {
        guard viewportElement.exists,
              anchorElement.exists,
              maximumStep > 0
        else {
            return false
        }
        if exists {
            return revealVertically(
                in: viewportElement,
                maxScrolls: maxScrolls,
                maximumStep: maximumStep)
        }

        for attempt in 0..<maxScrolls {
            let anchorFrame = anchorElement.exists
                ? anchorElement.frame
                : .null
            viewportElement.scroll(byDeltaX: 0, deltaY: maximumStep)
            let materializedOrMoved = waitForUITestCondition(
                timeout: 0.5,
                pollInterval: 0.02
            ) {
                if self.exists { return true }
                guard anchorElement.exists else { return false }
                let updatedAnchorFrame = anchorElement.frame
                return !anchorFrame.isEmpty
                    && !updatedAnchorFrame.isEmpty
                    && updatedAnchorFrame != anchorFrame
            }
            if exists {
                return revealVertically(
                    in: viewportElement,
                    maxScrolls: max(0, maxScrolls - attempt - 1),
                    maximumStep: maximumStep)
            }
            // An ignored wheel event is not terminal; the total attempt count
            // remains the bounded failure authority.
            if !materializedOrMoved { continue }
        }
        return false
    }

    @MainActor
    private func waitForStableContainedFrame(
        in viewportElement: XCUIElement,
        timeout: TimeInterval,
        stableFor stableInterval: TimeInterval = 0.1
    ) -> Bool {
        var candidateFrame: CGRect?
        var stableSince: Date?
        let stableProbeInterval = stableInterval > 0 ? stableInterval : 0.05
        return waitForUITestCondition(
            timeout: timeout,
            pollInterval: stableProbeInterval
        ) {
            let controlFrame = self.frame
            let viewportFrame = viewportElement.frame.insetBy(dx: 0, dy: 4)
            guard !controlFrame.isEmpty,
                  !viewportFrame.isEmpty,
                  viewportFrame.contains(controlFrame),
                  self.isHittable
            else {
                candidateFrame = nil
                stableSince = nil
                return false
            }
            if candidateFrame != controlFrame {
                candidateFrame = controlFrame
                stableSince = Date()
                return stableInterval <= 0
            }
            guard let stableSince else { return false }
            return Date().timeIntervalSince(stableSince) >= stableInterval
        }
    }
}

extension XCTestCase {
    @MainActor
    func attachScreenshot(of app: XCUIApplication, named name: String) {
        attachScreenshot(of: app, names: [name])
    }

    @MainActor
    func attachScreenshot(of app: XCUIApplication, names: [String]) {
        let window = app.windows.firstMatch
        let screenshot = window.screenshot()
        for name in names {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func attachElementScreenshot(of element: XCUIElement, named name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
