import AppKit
import XCTest

final class DictationUITests: PortavozUITestCase {
    @MainActor
    func testDictationCaptureFailureIsVisibleAndCanBeDismissed() async throws {
        let app = try XCUIApplication.portavoz(showMenuBarContent: true)
        app.launchArguments += ["-seed-dictation", "-seed-dictation-capture-failure"]
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] = #"{"globalDictationEnabled":true}"#
        app.launchPortavoz()
        defer { app.terminate() }
        let message = UITestLocale.environmentLocale == "es"
            ? "Se interrumpió la captura de audio. No se insertó nada. Vuelve a dictar."
            : "Audio capture was interrupted. Nothing was inserted. Try dictating again."

        for _ in 0..<2 {
            XCTAssertTrue(app.prepareForInteraction())
            let dictate = app.buttons["menu-bar-dictate"]
            XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
            dictate.click()
            let state = app.staticTexts["dictation-panel-state"]
            XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: state) == message })
            XCTAssertFalse(app.descendants(matching: .any)["dictation-panel-meter"].exists)
            let cancel = app.buttons["dictation-panel-cancel"]
            XCTAssertTrue(cancel.waitForStableFrame(timeout: 5))
            cancel.click()
            XCTAssertTrue(waitForUITestCondition(timeout: 5) { !cancel.exists })
        }
    }

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
    func testMicrophoneDenialRemainsRecoverableWithoutOpeningAudio() throws {
        let app = try XCUIApplication.portavoz(showMenuBarContent: true)
        app.launchArguments += ["-seed-dictation", "-seed-dictation-microphone-denied"]
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] = #"{"globalDictationEnabled":true}"#
        app.launchPortavoz()
        defer { app.terminate() }
        let dictate = app.buttons["menu-bar-dictate"]
        XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
        dictate.click()
        let state = app.staticTexts["dictation-panel-state"]
        let message = UITestLocale.environmentLocale == "es"
            ? "Permite el acceso al micrófono en Ajustes del Sistema y vuelve a intentar el dictado."
            : "Allow microphone access in System Settings, then try dictation again."
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: state) == message })
        XCTAssertFalse(app.descendants(matching: .any)["dictation-panel-meter"].exists)
        let cancel = app.buttons["dictation-panel-cancel"]
        XCTAssertTrue(cancel.waitForStableFrame(timeout: 5))
        cancel.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { !cancel.exists })
        XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
        dictate.click()
        let transcript = app.staticTexts["dictation-panel-transcript"]
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            renderedText(of: transcript).contains("No borres estas notas.")
        })
        XCTAssertTrue(cancel.waitForStableFrame(timeout: 5))
        cancel.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { !cancel.exists })
    }

    @MainActor
    func testMissingMicrophoneAudioShowsFallbackAndAllowsRestart() throws {
        let app = try XCUIApplication.portavoz(showMenuBarContent: true)
        app.launchArguments += ["-seed-dictation", "-seed-dictation-microphone-no-audio"]
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] = #"{"globalDictationEnabled":true}"#
        app.launchPortavoz()
        defer { app.terminate() }
        let dictate = app.buttons["menu-bar-dictate"]
        XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
        dictate.click()
        let state = app.staticTexts["dictation-panel-state"]
        let message = UITestLocale.environmentLocale == "es"
            ? "No llegó audio del micrófono. Revisa el micrófono en los ajustes de Audio e inténtalo de nuevo."
            : "No microphone audio arrived. Check the microphone in Audio settings and try again."
        XCTAssertTrue(waitForUITestCondition(timeout: 10) { renderedText(of: state) == message })
        let notice = app.staticTexts["dictation-panel-microphone-notice"]
        XCTAssertTrue(notice.exists)
        XCTAssertFalse(app.staticTexts["dictation-panel-transcript"].exists)
        let cancel = app.buttons["dictation-panel-cancel"]
        XCTAssertTrue(cancel.waitForStableFrame(timeout: 5))
        cancel.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { !cancel.exists })
        XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
        dictate.click()
        let transcript = app.staticTexts["dictation-panel-transcript"]
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            renderedText(of: transcript).contains("No borres estas notas.")
        })
        XCTAssertTrue(notice.exists)
        XCTAssertTrue(cancel.waitForStableFrame(timeout: 5))
        cancel.click()
    }

    @MainActor
    func testPreparingDictationCanCancelWithoutAListeningClaim() throws {
        let app = try XCUIApplication.portavoz(showMenuBarContent: true)
        app.launchArguments += ["-seed-dictation", "-seed-dictation-preparation-held"]
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] = #"{"globalDictationEnabled":true}"#
        app.launchPortavoz()
        defer { app.terminate() }
        let dictate = app.buttons["menu-bar-dictate"]
        XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
        dictate.click()
        let state = app.staticTexts["dictation-panel-state"]
        let title = UITestLocale.environmentLocale == "es" ? "Preparando el dictado…" : "Preparing dictation…"
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: state) == title })
        XCTAssertFalse(app.descendants(matching: .any)["dictation-panel-meter"].exists)
        XCTAssertFalse(app.staticTexts["dictation-panel-transcript"].exists)
        let cancel = app.buttons["dictation-panel-cancel"]
        XCTAssertTrue(cancel.waitForStableFrame(timeout: 5))
        cancel.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { !cancel.exists })
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
        let text = app.descendants(matching: .any)["dictation-recovery-text"]
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
        let text = app.descendants(matching: .any)["dictation-recovery-text"]
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
        app.activate()
        let discard = app.buttons["dictation-recovery-discard"]
        guard discard.isHittable else {
            return XCTFail("Activating the disposable menu window must not occlude recovery")
        }
        discard.click()
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

    @MainActor
    func testDeliveredDictationDistinguishesDispatchFromVerification() throws {
        for verified in [false, true] {
            let name = "app.portavoz.dictation-test." + UUID().uuidString
            let board = NSPasteboard(name: .init(name))
            defer { board.releaseGlobally() }
            board.setString("Original delivery clipboard", forType: .string)
            let app = try XCUIApplication.portavoz(showMenuBarContent: true)
            app.launchArguments += ["-seed-dictation", "-seed-dictation-delivery"]
            app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] = #"{"globalDictationEnabled":true}"#
            app.launchEnvironment["PORTAVOZ_UI_TEST_DICTATION_PASTEBOARD"] = name
            if UITestLocale.environmentLocale == "en" { app.launchArguments.append("-seed-dictation-english") }
            if verified { app.launchArguments.append("-seed-dictation-verified") }
            app.launchPortavoz()
            defer { app.terminate() }
            enterDestinationDelivery(app)
            let status = app.staticTexts["dictation-panel-delivery-status"]
            let title = renderedText(of: status)
            let detail = app.staticTexts["dictation-panel-delivery-detail"]
            XCTAssertTrue(detail.exists)
            XCTAssertFalse(app.buttons["dictation-recovery-reinsert"].exists,
                           "An unacknowledged event is not an automatically retryable refusal")
            if verified {
                XCTAssertTrue(title.contains("inserted") || title.contains("insertadas"), title)
                XCTAssertTrue(["Nothing was saved in Portavoz.", "No se guardó nada en Portavoz."]
                    .contains(renderedText(of: detail)))
                XCTAssertFalse(app.buttons["dictation-unverified-copy"].exists)
                XCTAssertTrue(waitForUITestCondition(timeout: 5) { !status.exists })
            } else {
                XCTAssertTrue(["Sent — insertion not verified", "Enviado — inserción sin verificar"]
                    .contains(title), title)
                assertUnverifiedRecovery(app, board: board)
            }
        }
    }

    @MainActor
    func testDictationSourceEOFBeforeStopIsVisibleAndCanRestart() throws {
        let english = UITestLocale.environmentLocale == "en"
        let app = try XCUIApplication.portavoz(showMenuBarContent: true)
        app.launchArguments += ["-seed-dictation", "-seed-dictation-source-eof"]
        if english { app.launchArguments.append("-seed-dictation-english") }
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] = #"{"globalDictationEnabled":true}"#
        app.launchPortavoz()
        defer { app.terminate() }
        let expectedText = english ? "Don't delete these notes." : "No borres estas notas."
        let expectedFailure = english
            ? "Audio capture was interrupted. Nothing was inserted. Try dictating again."
            : "Se interrumpió la captura de audio. No se insertó nada. Vuelve a dictar."

        for attempt in 0..<2 {
            XCTAssertTrue(app.prepareForInteraction())
            let dictate = app.buttons["menu-bar-dictate"]
            XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
            dictate.click()
            let state = app.staticTexts["dictation-panel-state"]
            let expectedState = attempt == 0 ? expectedFailure : (english ? "Dictating" : "Dictando")
            XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: state) == expectedState })
            if attempt == 0 {
                XCTAssertFalse(app.descendants(matching: .any)["dictation-panel-meter"].exists)
            } else {
                let transcript = app.staticTexts["dictation-panel-transcript"]
                XCTAssertTrue(waitForUITestCondition(timeout: 5) {
                    renderedText(of: transcript).contains(expectedText)
                })
            }
            let cancel = app.buttons["dictation-panel-cancel"]
            XCTAssertTrue(cancel.waitForStableFrame(timeout: 5))
            cancel.click()
            XCTAssertTrue(waitForUITestCondition(timeout: 5) { !cancel.exists })
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
        receiver.launchEnvironment["PORTAVOZ_RECEIVER_DELAY_EDITOR"] = "1"
        receiver.launch()
        defer { receiver.terminate() }
        let editor = receiver.textViews["dictation-receiver-editor"]
        let enableEditor = receiver.buttons["dictation-receiver-enable-editor"]
        XCTAssertTrue(enableEditor.waitForStableFrame(timeout: 5))
        XCTAssertFalse(editor.exists, "A foreground receiver is not necessarily an editable destination")
        let status = app.staticTexts["dictation-native-status"]
        XCTAssertEqual(renderedText(of: status), "waiting-for-receiver",
                       "Read-only readiness must not spend the single paste on a non-editor responder")
        enableEditor.click()
        XCTAssertTrue(editor.waitForExistenceFast(timeout: 5))
        // The receiver installs its own first responder. Clicking its coordinates
        // could activate an unrelated floating panel on a shared local host.
        guard waitForUITestCondition(timeout: 10, {
            renderedText(of: status) != "waiting-for-receiver"
        }) else {
            XCTFail("Native delivery must leave its receiver-waiting state")
            return
        }
        let deliveryStatus = renderedText(of: status)
        let permissionHelp = deliveryStatus == "accessibility-required-for-app"
            ? " Grant Accessibility to the disposable app, not the runner." : ""
        XCTAssertEqual(deliveryStatus, "verified", "Native delivery status: \(deliveryStatus).\(permissionHelp)")
        let text = "Don't delete — no borres: café, C++, 1.250,50 €."
        _ = waitForUITestCondition(timeout: 5) { editor.value as? String == text }
        XCTAssertEqual(editor.value as? String, text, "Inspect actual receiver content, not event dispatch alone")
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            pasteboard.string(forType: .string) == "original fixture"
        })
    }

    @MainActor
    func testNativeControllerModeChoicePreservesReceiverAndClipboard() async throws {
        let receiverURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("PortavozDictationReceiver.app")
        let receiver = XCUIApplication(url: receiverURL)
        let name = "app.portavoz.dictation-test.\(UUID().uuidString)"
        let pasteboard = NSPasteboard(name: .init(name))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("original controller fixture", forType: .string)
        let controlName = "app.portavoz.dictation-test.\(UUID().uuidString)"
        let controlBoard = NSPasteboard(name: .init(controlName))
        controlBoard.clearContents()
        defer { controlBoard.releaseGlobally() }
        let app = try XCUIApplication.portavoz(showMenuBarContent: true)
        app.launchEnvironment["PORTAVOZ_UI_TEST_DICTATION_CONTROL_PASTEBOARD"] = controlName
        app.launchArguments += ["-seed-dictation-native", "-seed-dictation-native-controller",
                                "-seed-dictation", "-seed-dictation-english"]
        app.launchEnvironment["PORTAVOZ_UI_TEST_DICTATION_PASTEBOARD"] = name
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] =
            #"{"globalDictationEnabled":true,"dictationTextMode":"literal","dictationApplicationTextProfiles":"[]","dictationReplacements":"[{\"trigger\":\"notes\",\"replacement\":\"documents\"}]"}"#
        app.launchPortavoz()
        defer { app.terminate() }
        let start = app.buttons["dictation-native-start"]
        XCTAssertTrue(start.waitForStableFrame(timeout: 5))
        start.click()
        let status = app.staticTexts["dictation-native-status"]
        guard renderedText(of: status) == "waiting-for-receiver" else {
            XCTFail("Native controller fixture did not arm: \(renderedText(of: status))")
            return
        }
        try UITestStorage.register(receiver)
        receiver.launchEnvironment["PORTAVOZ_RECEIVER_PASTEBOARD"] = name
        receiver.launch()
        defer { receiver.terminate() }
        let editor = receiver.textViews["dictation-receiver-editor"]
        XCTAssertTrue(editor.waitForExistenceFast(timeout: 5))
        let transcript = app.staticTexts["dictation-panel-transcript"]
        guard waitForUITestCondition(timeout: 5, {
            renderedText(of: transcript).contains("Don't delete these notes.")
        }) else {
            XCTFail("The real controller must recognize the scripted caption before the mode choice")
            return
        }
        let mode = app.menuButtons["dictation-panel-text-mode"]
        XCTAssertTrue(renderedText(of: mode).contains("Literal"))
        try clickNonactivatingControl(mode, from: receiver)
        let clean = app.menuItems["dictation-panel-text-mode-clean"]
        // The gesture helper already waits for an actionable stable control;
        // a separate existence probe would repeat the same remote admission.
        try clickNonactivatingControl(clean, from: receiver)
        // Gesture acknowledgement precedes Stop. Posting Paste from inside an
        // in-flight XCTest pointer action does not model a subsequent user Stop.
        XCTAssertTrue(controlBoard.setString("stop", forType: .string))
        // Never activate or click the receiver after the panel interaction:
        // repairing focus in the test would hide a broken destination fence.
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            renderedText(of: status) != "controller-listening"
        })
        XCTAssertEqual(renderedText(of: status), "verified", "The native receiver must observe the edit")
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            editor.value as? String == "Don't delete these documents."
        })
        XCTAssertEqual(editor.value as? String, "Don't delete these documents.",
                       "Read back the transformed text from the original receiver, not a dispatched event")
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            pasteboard.string(forType: .string) == "original controller fixture"
        })
        XCTAssertTrue(mode.waitForDisappearance(timeout: 5), "The fixture must retire its own session")
    }


    @MainActor
    private func clickNonactivatingControl(_ control: XCUIElement, from receiver: XCUIApplication) throws {
        // Background element.click() activates its app before synthesizing input.
        // Anchor the public pointer API in the already foreground owned receiver,
        // at the actual panel control's stable screen location. Do not repair focus.
        _ = try XCTUnwrap(receiver.state == .runningForeground ? receiver : nil,
                          "The original receiver must still be foreground before the mode gesture")
        _ = try XCTUnwrap(control.waitForStableFrame(timeout: 5) ? control : nil)
        let frame = control.frame
        let window = receiver.windows.firstMatch
        // The editor witness already admitted this owned window. Reading its
        // current frame still rejects disappearance without an extra exists IPC.
        let anchor = window.frame
        _ = try XCTUnwrap(anchor.width > 0 && anchor.height > 0 && anchor.minX.isFinite && anchor.minY.isFinite
                         ? anchor : nil, "An application's synthetic infinite frame is not a pointer anchor")
        let origin = anchor.origin
        _ = try XCTUnwrap(frame.width > 0 && frame.height > 0 && frame.midX.isFinite && frame.midY.isFinite
                         ? frame : nil, "Never synthesize a pointer action at an unavailable control")
        window.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: frame.midX - origin.x, dy: frame.midY - origin.y)).click()
    }

}

private extension DictationUITests {
    var recoveryFixtureText: String {
        UITestLocale.environmentLocale == "en" ? "Don't delete these notes." : "No borres estas notas."
    }

    @MainActor
    func enterDestinationRecovery(_ app: XCUIApplication) {
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
    func enterDestinationDelivery(_ app: XCUIApplication) {
        XCTAssertTrue(app.prepareForInteraction())
        let dictate = app.buttons["menu-bar-dictate"]
        XCTAssertTrue(dictate.waitForStableFrame(timeout: 5))
        dictate.click()
        XCTAssertTrue(app.staticTexts["dictation-panel-transcript"].waitForExistenceFast(timeout: 5))
        dictate.click()
        XCTAssertTrue(app.staticTexts["dictation-panel-delivery-status"].waitForExistenceFast(timeout: 5))
    }

    @MainActor
    func assertUnverifiedRecovery(_ app: XCUIApplication, board: NSPasteboard) {
        let text = app.staticTexts["dictation-unverified-text"]
        XCTAssertEqual(renderedText(of: text), recoveryFixtureText)
        let status = app.staticTexts["dictation-unverified-copy-status"]
        let originalStatus = renderedText(of: status)
        let panel = app.dialogs["dictation-panel"]
        let originalFrame = panel.frame
        for identifier in ["dictation-unverified-copy", "dictation-unverified-discard"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForStableFrame(timeout: 5))
            XCTAssertFalse(button.label.isEmpty)
            XCTAssertEqual(app.buttons.matching(identifier: identifier).count, 1)
            XCTAssertTrue(originalFrame.contains(button.frame))
        }
        let copy = app.buttons["dictation-unverified-copy"]
        copy.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { renderedText(of: status) != originalStatus })
        XCTAssertEqual(board.string(forType: .string), "Original delivery clipboard")
        XCTAssertTrue(text.exists, "Failed Copy must preserve output")
        copy.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { board.string(forType: .string) == recoveryFixtureText })
        let dictate = app.buttons["menu-bar-dictate"]
        XCTAssertFalse(originalFrame.intersects(dictate.frame))
        dictate.click()
        // An unverified notice is non-modal: the next dictation starts and
        // replaces it, and the previous output is not sent again.
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { !text.exists }, "Another trigger starts a new capture")
        let cancel = app.buttons["dictation-panel-cancel"]
        XCTAssertTrue(cancel.waitForStableFrame(timeout: 5))
        XCTAssertEqual(board.string(forType: .string), recoveryFixtureText, "A new capture never re-sends output")
        app.activate()
        cancel.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { !panel.exists }, "Cancel must exit in one action")
    }

}
