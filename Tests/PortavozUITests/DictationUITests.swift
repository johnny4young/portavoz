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
    func testStreamingDictationKeepsClosedRowsThroughCancellationAndRestart() throws {
        let app = try XCUIApplication.portavoz(showMenuBarContent: true)
        app.launchArguments += ["-seed-dictation", "-seed-dictation-streaming"]
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] = #"{"globalDictationEnabled":true}"#
        app.launchPortavoz()
        defer { app.terminate() }
        XCTAssertTrue(app.prepareForInteraction())
        let dictate = app.buttons["menu-bar-dictate"]
        let expected = "No borres estas notas. Café C++. Final"
        for _ in 0..<2 {
            XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
            dictate.click()
            let transcript = app.staticTexts["dictation-panel-transcript"]
            XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: transcript) == expected })
            let cancel = app.buttons["dictation-panel-cancel"]
            XCTAssertTrue(cancel.waitForStableFrame(timeout: 5))
            cancel.click()
            XCTAssertTrue(waitForUITestCondition(timeout: 5) { !transcript.exists })
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
        guard renderedText(of: status) == "inserted" else {
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
