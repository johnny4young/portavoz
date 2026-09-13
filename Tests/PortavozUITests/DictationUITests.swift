import AppKit
import XCTest

final class DictationUITests: PortavozUITestCase {
    @MainActor
    func testDictationPanelCancelsAndRestartsWithoutGlobalInput() throws {
        let app = try XCUIApplication.portavoz(showMenuBarContent: true)
        app.launchArguments.append("-seed-dictation")
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] =
            #"{"globalDictationEnabled":true,"dictationMouseButton":2}"#
        app.launchPortavoz()
        defer { app.terminate() }

        for _ in 0..<2 {
            XCTAssertTrue(app.prepareForInteraction())
            let dictate = app.buttons["menu-bar-dictate"]
            XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
            dictate.click()
            let transcript = app.staticTexts["dictation-panel-transcript"]
            guard transcript.waitForExistenceFast(timeout: 5) else {
                XCTFail("The running dictation must expose its transcript independently of the panel container.")
                return
            }
            XCTAssertTrue(waitForUITestCondition(timeout: 5) {
                renderedText(of: transcript).contains("No borres estas notas.")
            })
            for identifier in ["dictation-panel-state", "dictation-panel-target", "dictation-panel-meter"] {
                XCTAssertEqual(app.descendants(matching: .any).matching(identifier: identifier).count, 1)
            }
            let cancel = app.buttons["dictation-panel-cancel"]
            XCTAssertTrue(cancel.waitForStableFrame(timeout: 5))
            cancel.click()
            XCTAssertTrue(waitForUITestCondition(timeout: 5) { !cancel.exists })
        }
    }

    @MainActor
    func testUndeliveredTextCanBeCopiedAndExplicitlyRetried() throws {
        let name = "app.portavoz.dictation-test." + UUID().uuidString
        let board = NSPasteboard(name: .init(name))
        defer { board.releaseGlobally() }
        board.setString("Original recovery clipboard", forType: .string)
        let app = try XCUIApplication.portavoz(showMenuBarContent: true)
        app.launchArguments += ["-seed-dictation", "-seed-dictation-recovery"]
        if UITestLocale.environmentLocale == "en" { app.launchArguments.append("-seed-dictation-english") }
        app.launchEnvironment["PORTAVOZ_UI_TEST_DICTATION_PASTEBOARD"] = name
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] = #"{"globalDictationEnabled":true}"#
        app.launchPortavoz()
        defer { app.terminate() }
        enterDestinationRecovery(app)
        let text = app.staticTexts["dictation-recovery-text"]
        XCTAssertTrue(renderedText(of: text).contains(recoveryFixtureText))
        let status = app.staticTexts["dictation-recovery-copy-status"]
        let initial = renderedText(of: status)
        for identifier in ["dictation-recovery-copy", "dictation-recovery-reinsert", "dictation-recovery-discard"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForStableFrame(timeout: 5))
            XCTAssertFalse(button.label.isEmpty)
            XCTAssertEqual(app.buttons.matching(identifier: identifier).count, 1)
            XCTAssertTrue(app.dialogs["dictation-panel"].frame.contains(button.frame),
                          "Long destination names must not push recovery actions outside the panel")
        }
        app.buttons["dictation-recovery-copy"].click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: status) != initial })
        XCTAssertEqual(board.string(forType: .string), "Original recovery clipboard")
        XCTAssertTrue(text.exists, "A failed copy must retain the output")
        app.buttons["dictation-recovery-copy"].click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { board.string(forType: .string) == recoveryFixtureText })
        XCTAssertTrue(text.exists, "Copy does not discard the user's recovery option")
        app.buttons["dictation-recovery-reinsert"].click()
        XCTAssertTrue(app.staticTexts["dictation-panel-delivery-status"].waitForExistenceFast(timeout: 5))
        XCTAssertFalse(text.exists)
    }

    @MainActor
    func testUndeliveredTextSurvivesAnotherTriggerUntilDiscarded() throws {
        let app = try XCUIApplication.portavoz(showMenuBarContent: true)
        app.launchArguments += ["-seed-dictation", "-seed-dictation-recovery"]
        if UITestLocale.environmentLocale == "en" { app.launchArguments.append("-seed-dictation-english") }
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] = #"{"globalDictationEnabled":true}"#
        app.launchPortavoz()
        defer { app.terminate() }
        enterDestinationRecovery(app)
        let text = app.staticTexts["dictation-recovery-text"]
        let original = renderedText(of: text)
        let originalFrame = app.dialogs["dictation-panel"].frame
        let dictate = app.buttons["menu-bar-dictate"]
        XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
        guard !originalFrame.intersects(dictate.frame) else {
            return XCTFail("The menu fixture must not place Dictate beneath the recovery panel")
        }
        dictate.click()
        XCTAssertTrue(app.buttons["dictation-recovery-discard"].waitForStableFrame(timeout: 5))
        XCTAssertEqual(renderedText(of: text), original)
        XCTAssertEqual(app.dialogs["dictation-panel"].frame, originalFrame,
                       "Revealing retained text must not move a self-sizing panel")
        app.buttons["dictation-recovery-discard"].click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { !app.dialogs["dictation-panel"].exists },
                      "Discard must close the whole panel before another global trigger")
        XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
        dictate.click()
        XCTAssertTrue(app.staticTexts["dictation-panel-transcript"].waitForExistenceFast(timeout: 5))
        let cancel = app.buttons["dictation-panel-cancel"]
        XCTAssertTrue(cancel.waitForStableFrame(timeout: 5))
        cancel.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { !cancel.exists })
    }

    private var recoveryFixtureText: String {
        UITestLocale.environmentLocale == "en" ? "Don't delete these notes." : "No borres estas notas."
    }

    @MainActor
    private func enterDestinationRecovery(_ app: XCUIApplication) {
        XCTAssertTrue(app.prepareForInteraction())
        let dictate = app.buttons["menu-bar-dictate"]
        XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
        dictate.click()
        XCTAssertTrue(app.staticTexts["dictation-panel-transcript"].waitForExistenceFast(timeout: 5))
        XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
        dictate.click()
        XCTAssertTrue(app.staticTexts["dictation-recovery-title"].waitForExistenceFast(timeout: 5))
    }

    @MainActor
    func testDeliveredDictationDistinguishesDispatchFromVerification() {
        for verified in [false, true] {
            let app = XCUIApplication.portavoz(showMenuBarContent: true)
            app.launchArguments += ["-seed-dictation", "-seed-dictation-delivery"]
            app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] = #"{"globalDictationEnabled":true}"#
            if verified { app.launchArguments.append("-seed-dictation-verified") }
            app.launchPortavoz()
            defer { app.terminate() }
            XCTAssertTrue(app.prepareForInteraction())
            let dictate = app.buttons["menu-bar-dictate"]
            XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
            dictate.click()
            XCTAssertTrue(app.staticTexts["dictation-panel-transcript"].waitForExistenceFast(timeout: 5))
            XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
            dictate.click()
            let status = app.staticTexts["dictation-panel-delivery-status"]
            XCTAssertTrue(status.waitForExistenceFast(timeout: 5))
            let title = renderedText(of: status)
            if verified {
                XCTAssertTrue(title.contains("inserted") || title.contains("insertadas"), title)
            } else {
                XCTAssertTrue(["Sent — insertion not verified", "Enviado — inserción sin verificar"].contains(title), title)
            }
            let detail = app.staticTexts["dictation-panel-delivery-detail"]
            XCTAssertTrue(detail.exists)
            if verified {
                XCTAssertTrue(["Nothing was saved in Portavoz.", "No se guardó nada en Portavoz."].contains(renderedText(of: detail)))
            }
            XCTAssertFalse(app.buttons["dictation-recovery-reinsert"].exists,
                           "An unacknowledged event is not an automatically retryable refusal")
            XCTAssertTrue(waitForUITestCondition(timeout: 5) { !status.exists },
                          "An unsupported editor must not strand a modal result")
        }
    }

    @MainActor
    func testNativeInserterUsesDisposableReceiverAndClipboard() async throws {
        let products = Bundle.main.bundleURL.deletingLastPathComponent()
        let receiverURL = products.appendingPathComponent("PortavozDictationReceiver.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiverURL.path))
        let receiver = XCUIApplication(url: receiverURL)
        let name = "app.portavoz.dictation-test.\(UUID().uuidString)"
        let pasteboard = NSPasteboard(name: .init(name))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("original fixture", forType: .string)
        let app = try XCUIApplication.portavoz(showMenuBarContent: true)
        app.launchArguments.append("-seed-dictation-native")
        app.launchEnvironment["PORTAVOZ_UI_TEST_DICTATION_PASTEBOARD"] = name
        app.launchPortavoz()
        defer { app.terminate() }
        let start = app.buttons["dictation-native-start"]
        guard start.waitForStableFrame(timeout: 5) else {
            return XCTFail("The isolated native insertion fixture must be explicitly armed")
        }
        start.click()
        start.click() // Re-arming while waiting must not enqueue a second paste.
        try UITestStorage.register(receiver)
        receiver.launchEnvironment["PORTAVOZ_RECEIVER_PASTEBOARD"] = name
        receiver.launch()
        defer { receiver.terminate() }
        let editor = receiver.textViews["dictation-receiver-editor"]
        XCTAssertTrue(editor.waitForExistenceFast(timeout: 5))
        // The receiver installs its own first responder. Clicking its coordinates
        // could activate an unrelated floating panel on a shared local host.
        let status = app.staticTexts["dictation-native-status"]
        guard waitForUITestCondition(timeout: 10, {
            renderedText(of: status) != "waiting-for-receiver"
        }) else {
            XCTFail("Native delivery must leave its receiver-waiting state")
            return
        }
        guard renderedText(of: status) == "verified" else {
            let failure = renderedText(of: status)
            let permissionHelp = failure == "accessibility-required-for-app"
                ? " Grant Accessibility to the disposable app, not the runner." : ""
            XCTFail("Native delivery status: \(failure).\(permissionHelp)")
            return
        }
        let text = "Don't delete — no borres: café, C++, 1.250,50 €."
        _ = waitForUITestCondition(timeout: 5) { editor.value as? String == text }
        XCTAssertEqual(editor.value as? String, text, "Inspect actual receiver content, not event dispatch alone")
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            pasteboard.string(forType: .string) == "original fixture"
        })
    }
}
