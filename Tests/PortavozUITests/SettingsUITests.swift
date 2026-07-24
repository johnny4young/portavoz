import XCTest

/// The redesigned Settings (design system 2a): a category sidebar with the
/// panes behind it. These verify the navigation works and that the
/// app-only language override updates SwiftUI text live.
final class SettingsUITests: XCTestCase {
    @MainActor
    func testLocalDataLedgerShowsExactCountsAndHonestNetworkPolicy() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        app.typeKey(",", modifierFlags: .command)
        let data = app.control(withIdentifier: "settings-category-data")
        XCTAssertTrue(data.waitForExistence(timeout: 10))
        data.click()

        let localFirstSeal = Locale.current.identifier.hasPrefix("es")
            ? "Local primero"
            : "Local-first"
        let privacySeal = app.buttons["settings-privacy-seal"]
        XCTAssertTrue(privacySeal.waitForExistence(timeout: 5))
        XCTAssertTrue(
            privacySeal.label.contains(localFirstSeal),
            "the standing privacy seal must describe the opt-in architecture without an absolute all-local claim")

        let meetings = app.control(withIdentifier: "settings-ledger-meetings")
        XCTAssertTrue(meetings.waitForExistence(timeout: 10))
        let loadedMeetings = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == '1'"),
            object: meetings)
        XCTAssertEqual(XCTWaiter.wait(for: [loadedMeetings], timeout: 10), .completed)
        let audio = app.control(withIdentifier: "settings-ledger-audio")
        XCTAssertTrue(audio.exists)
        XCTAssertFalse((audio.value as? String)?.isEmpty ?? true)
        XCTAssertNotEqual(audio.value as? String, "…")
        let voices = app.control(withIdentifier: "settings-ledger-voices")
        XCTAssertEqual(voices.value as? String, "0")
        let network = app.control(withIdentifier: "settings-ledger-network-policy")
        XCTAssertTrue(network.exists)
        let expectedPolicy = Locale.current.identifier.hasPrefix("es")
            ? "Con activación"
            : "Opt-in"
        XCTAssertEqual(network.value as? String, expectedPolicy)
        attachScreenshot(of: app, named: "local-data-ledger")
    }

    @MainActor
    func testCategoryNavigationRevealsEachPane() {
        let app = XCUIApplication.portavoz(openSettings: true)
        app.launchPortavoz()
        defer { app.terminate() }

        // The nav renders every category…
        let intelligence = app.control(withIdentifier: "settings-category-intelligence")
        XCTAssertTrue(
            intelligence.waitForExistence(timeout: 10),
            "the Settings category sidebar must render (2a)")
        XCTAssertTrue(app.control(withIdentifier: "settings-category-data").exists)
        XCTAssertTrue(app.control(withIdentifier: "settings-category-sync").exists)

        // …and picking Intelligence reveals the summary-engine picker, which
        // now lives in that pane rather than one long scroll (M12).
        intelligence.click()
        XCTAssertTrue(
            app.control(withIdentifier: "settings-summary-engine-picker").waitForExistence(timeout: 5),
            "the Intelligence pane must show the summary-engine picker")
        XCTAssertTrue(
            app.control(withIdentifier: "settings-summary-language").waitForExistence(timeout: 5),
            "the Intelligence pane must separate summary output from spoken language")
        XCTAssertTrue(
            app.control(withIdentifier: "settings-whisper-turbo").waitForExistence(timeout: 5),
            "the Intelligence pane must expose the Turbo Whisper variant")
        let whisperDownload = app.control(withIdentifier: "settings-whisper-download-turbo")
        XCTAssertTrue(
            whisperDownload.exists,
            "a clean install must offer proactive Whisper preparation before Refine")
        let settingsWindow = app.windows.containing(
            .any,
            identifier: "settings-whisper-turbo"
        ).firstMatch
        XCTAssertTrue(settingsWindow.exists)
        // The first scroll view is the category sidebar; the second is the
        // grouped Form that owns the model controls.
        let settingsForm = settingsWindow.scrollViews.element(boundBy: 1)
        XCTAssertTrue(settingsForm.exists)
        func downloadIsVisible() -> Bool {
            let visibleFormFrame = settingsForm.frame.intersection(settingsWindow.frame)
            let downloadFrame = whisperDownload.frame
            return !visibleFormFrame.isEmpty
                && !downloadFrame.isEmpty
                && downloadFrame.intersects(visibleFormFrame)
        }
        // GitHub's macOS runner exposes a 760x650 Settings viewport, so the
        // Whisper action starts farther below the fold than on a developer Mac.
        for _ in 0..<24 {
            if downloadIsVisible() {
                break
            }
            settingsForm.scroll(byDeltaX: 0, deltaY: -6)
        }
        XCTAssertTrue(
            downloadIsVisible(),
            "the proactive Whisper action must be visible before capturing UI evidence")
        let attachment = XCTAttachment(screenshot: settingsWindow.screenshot())
        attachment.name = "sequoia-whisper-background-settings"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Your data shows the export action.
        app.control(withIdentifier: "settings-category-data").click()
        XCTAssertTrue(
            app.buttons["settings-export-all-button"].waitForExistence(timeout: 5),
            "the Your-data pane must show the export-all action")
        XCTAssertTrue(
            app.buttons["settings-recordings-change"].waitForExistence(timeout: 5),
            "recording storage must load through the application boundary")
        attachScreenshot(of: app, named: "settings-recording-storage")
    }

    @MainActor
    func testSyncPaneKeepsOptInAndExistingLibrarySeparate() {
        let app = XCUIApplication.portavoz(openSettings: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let sync = app.control(withIdentifier: "settings-category-sync")
        XCTAssertTrue(
            sync.waitForExistence(timeout: 10),
            "Settings must expose a dedicated iCloud sync pane")
        sync.click()

        XCTAssertTrue(
            app.staticTexts["settings-sync-status"].waitForExistence(timeout: 5),
            "the sync pane must show truthful local-only status before opt-in")
        let enable = app.buttons["settings-sync-enable"]
        XCTAssertTrue(
            enable.waitForExistence(timeout: 5),
            "a local-only library must require an explicit Enable action")
        XCTAssertFalse(app.buttons["settings-sync-seed"].exists)

        enable.click()

        XCTAssertTrue(
            app.buttons["settings-sync-now"].waitForExistence(timeout: 5),
            "enablement must reveal a manual sync action")
        XCTAssertTrue(
            app.buttons["settings-sync-seed"].waitForExistence(timeout: 5),
            "existing meetings must remain a separate explicit action")
        XCTAssertTrue(app.buttons["settings-sync-pause"].exists)
        XCTAssertTrue(app.buttons["settings-sync-remove"].exists)
        let privacySeal = app.buttons["settings-privacy-seal"]
        XCTAssertTrue(privacySeal.waitForExistence(timeout: 5))
        let reflectsCloudSync = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "iCloud"),
            object: privacySeal)
        XCTAssertEqual(
            XCTWaiter.wait(for: [reflectsCloudSync], timeout: 5),
            .completed,
            "the standing privacy seal must stop claiming that everything is local")
        attachScreenshot(of: app, named: "band-6c-cloud-sync")
    }

    @MainActor
    func testDataPaneExportsARedactedLocalSupportFile() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-support-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: destination) }
        let app = XCUIApplication.portavoz(seedDemo: true, openSettings: true)
        app.launchEnvironment["PORTAVOZ_UI_TEST_DIAGNOSTICS_PATH"] = destination.path
        app.launchPortavoz()
        defer { app.terminate() }

        let dataCategory = app.control(withIdentifier: "settings-category-data")
        XCTAssertTrue(dataCategory.waitForExistence(timeout: 10))
        dataCategory.click()

        let export = app.buttons["settings-export-diagnostics"]
        XCTAssertTrue(
            export.waitForExistence(timeout: 5),
            "the Your-data pane must offer an explicit redacted support export")
        export.click()
        XCTAssertTrue(
            app.staticTexts["settings-diagnostics-status"].waitForExistence(timeout: 10),
            "the export must confirm that no meeting content was included")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let text = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(text.contains("\"formatVersion\" : 2"))
        XCTAssertTrue(text.contains("\"audioAssets\""))
        XCTAssertTrue(text.contains("\"transcript\""))
        XCTAssertFalse(text.contains("relativePath"))
        XCTAssertFalse(text.contains("sha256"))
        XCTAssertFalse(text.contains("Revisemos el presupuesto de transcripción."))
        attachScreenshot(of: app, named: "band-3i-redacted-support-export")
    }

    @MainActor
    func testDataPaneExportsAReadableWholeLibraryMarkdownBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication.portavoz(seedDemo: true, openSettings: true)
        app.launchEnvironment["PORTAVOZ_UI_TEST_BACKUP_FOLDER"] = directory.path
        app.launchPortavoz()
        defer { app.terminate() }

        let dataCategory = app.control(withIdentifier: "settings-category-data")
        XCTAssertTrue(dataCategory.waitForExistence(timeout: 10))
        dataCategory.click()

        let export = app.buttons["settings-export-all-button"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.click()
        let status = app.staticTexts["settings-backup-status"]
        XCTAssertTrue(
            status.waitForExistence(timeout: 15),
            "the backup must finish with a visible result")
        let expectedStatus = Locale.current.identifier.hasPrefix("es")
            ? "1 reunión exportada."
            : "1 meeting exported."
        XCTAssertTrue(
            app.staticTexts[expectedStatus].exists,
            "the completion copy must use the locale-correct singular form")

        let markdownFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "md" }
        XCTAssertFalse(markdownFiles.isEmpty)
        let exportedText = try markdownFiles.map {
            try String(contentsOf: $0, encoding: .utf8)
        }.joined(separator: "\n")
        XCTAssertTrue(exportedText.contains("# Test meeting"))
        XCTAssertTrue(exportedText.contains("Revisemos el presupuesto de transcripción."))
        attachScreenshot(of: app, named: "band-6c4-markdown-backup")
    }

    @MainActor
    func testIntelligencePaneCreatesACustomStructure() {
        // The Intelligence pane lets you author your own summary structures;
        // "Add structure" opens the editor sheet with a name field.
        let app = XCUIApplication.portavoz(openSettings: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let intelligence = app.control(withIdentifier: "settings-category-intelligence")
        XCTAssertTrue(intelligence.waitForExistence(timeout: 10))
        intelligence.click()

        let add = app.buttons["settings-add-structure"]
        XCTAssertTrue(
            add.waitForExistence(timeout: 5),
            "the Intelligence pane must offer the custom-structure creator")
        add.click()

        XCTAssertTrue(
            app.textFields["structure-name"].waitForExistence(timeout: 5),
            "Add structure must open the editor sheet with a name field")
    }

    @MainActor
    func testAudioPaneOffersCaptureSourceControls() {
        // Capture control (field feedback): pick your mic and what to record
        // for the other side, independent of AirPods.
        let app = XCUIApplication.portavoz(openSettings: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let audio = app.control(withIdentifier: "settings-category-audio")
        XCTAssertTrue(audio.waitForExistence(timeout: 10))
        audio.click()

        XCTAssertTrue(
            app.control(withIdentifier: "settings-mic-device").waitForExistence(timeout: 5),
            "the Audio pane must offer a microphone picker")
        XCTAssertTrue(
            app.control(withIdentifier: "settings-capture-mode").waitForExistence(timeout: 5),
            "the Audio pane must offer a capture-source picker")
        let callSafePolicy = app.control(withIdentifier: "settings-call-safe-capture")
        XCTAssertTrue(
            callSafePolicy.waitForStableFrame(),
            "the Audio pane must expose a stable always-on call-safe capture policy")
        attachScreenshot(of: app, named: "call-safe-audio-settings")
    }

    /// Enabling dictation must reveal both physical triggers (hotkey +
    /// push-to-talk mouse button), the {es,en}-constrained language picker,
    /// the filler filter, and the deterministic dictionary quick-add.
    @MainActor
    func testDictationOffersTriggersLanguageAndDictionary() {
        let app = XCUIApplication.portavoz(openSettings: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let audio = app.control(withIdentifier: "settings-category-audio")
        XCTAssertTrue(audio.waitForExistence(timeout: 10))
        audio.click()

        let toggle = app.control(withIdentifier: "settings-dictation-toggle")
        XCTAssertTrue(
            toggle.waitForExistence(timeout: 5),
            "the Audio pane must offer the dictation enable toggle")
        // The app under test shares the real UserDefaults, so dictation may
        // already be on — ENSURE enabled instead of toggling blind, and put
        // the user's original state back afterwards.
        let wasEnabled = Self.isOn(toggle)
        if !wasEnabled { toggle.click() }
        defer { if !wasEnabled { toggle.click() } }

        XCTAssertTrue(
            app.control(withIdentifier: "settings-dictation-hotkey-recorder")
                .waitForExistence(timeout: 5),
            "enabling dictation must reveal the hotkey recorder")
        XCTAssertTrue(
            app.control(withIdentifier: "settings-dictation-mouse-recorder").exists,
            "enabling dictation must reveal the push-to-talk mouse-button recorder")
        XCTAssertTrue(
            app.control(withIdentifier: "settings-dictation-language").exists,
            "enabling dictation must reveal the constrained language picker")
        XCTAssertTrue(
            app.control(withIdentifier: "settings-dictation-filler").exists,
            "enabling dictation must reveal the filler-word filter toggle")
        XCTAssertTrue(
            app.control(withIdentifier: "settings-dictation-dict-add").exists,
            "enabling dictation must reveal the dictionary quick-add")
    }

    @MainActor
    func testVoicePaneOffersTheMirrorOptIn() {
        // The post-meeting mirror (6a-2) is opt-in and off by default; its
        // switch lives in the "My voice & Apuntador" pane.
        let app = XCUIApplication.portavoz(openSettings: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let voice = app.control(withIdentifier: "settings-category-voice")
        XCTAssertTrue(voice.waitForExistence(timeout: 10))
        voice.click()

        let mirror = app.control(withIdentifier: "settings-mirror-after-meeting")
        XCTAssertTrue(
            mirror.waitForExistence(timeout: 5),
            "the voice pane must offer the post-meeting mirror opt-in")
        XCTAssertTrue(
            app.control(withIdentifier: "settings-voice-enroll").exists,
            "a disposable library must expose local voice enrollment")
        attachScreenshot(of: app, named: "local-voice-enrollment")
    }

    @MainActor
    func testLanguageToggleSwitchesVisibleTextWithoutRelaunch() {
        // The standalone Settings window (⌘,), not the test sheet: the sheet
        // clips the trailing-edge toggle, the real window lays it out fully.
        let app = XCUIApplication.portavoz(launchLocale: "en")
        app.launchPortavoz()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["library-new-recording-button"].waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)  // open Settings

        let systemToggle = app.control(withIdentifier: "settings-language-system-toggle")
        XCTAssertTrue(systemToggle.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Use system language"].exists)

        systemToggle.click()  // manual English by default
        let languagePicker = app.control(withIdentifier: "settings-language-picker")
        XCTAssertTrue(languagePicker.waitForExistence(timeout: 5))
        languagePicker.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).click()
        // The whole UI re-localizes live: the pane label AND a nav category.
        XCTAssertTrue(app.staticTexts["Usar idioma del sistema"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["General e idioma"].exists)

        systemToggle.click()  // back to launch/system English
        XCTAssertTrue(app.staticTexts["Use system language"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["General & language"].exists)
    }

    /// A macOS checkbox reports its state as "1"/1 through Accessibility.
    private static func isOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? Int) == 1 || (toggle.value as? String) == "1"
    }
}
