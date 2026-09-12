import XCTest

final class SettingsTransferUITests: PortavozUITestCase {
    @MainActor
    func testPortablePreferencesReviewCancelApplyAndLiveLanguage() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.json")
        let output = directory.appendingPathComponent("output.json")
        let target = UITestLocale.environmentLocale == "es" ? "en" : "es"
        try writeSettings(["interfaceLanguage": target, "vocabulary": "Cóndor, Don’t, C++"], to: input)
        let app = application(input: input, output: output)
        app.launchPortavoz()
        defer { app.terminate() }
        XCTAssertTrue(app.openSettingsCategory("settings-category-data", revealing: "settings-export-preferences"))

        let export = app.buttons["settings-export-preferences"]
        XCTAssertTrue(export.exists)
        export.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { FileManager.default.fileExists(atPath: output.path) })
        let before = try settings(at: output)
        XCTAssertEqual(before["vocabulary"] as? String, "Existing")
        XCTAssertEqual(Set(before.keys), ["interfaceLanguage", "recognitionLanguage", "summaryLanguage",
            "menuBarVisible", "titleTemplate", "vocabulary", "dictationLanguage", "removeFillers", "replacements"])
        let importButton = app.buttons["settings-import-preferences"]
        XCTAssertTrue(importButton.isEnabled)
        importButton.click()
        let review = app.staticTexts["settings-preferences-review"]
        XCTAssertTrue(review.waitForExistenceFast(timeout: 5))
        XCTAssertEqual(renderedText(of: app.staticTexts["settings-preferences-change-interfaceLanguage"]), target)
        XCTAssertEqual(renderedText(of: app.staticTexts["settings-preferences-change-vocabulary"]),
                       "Existing, Cóndor, Don’t, C++")
        let cancel = app.buttons["settings-preferences-cancel"]
        XCTAssertTrue(cancel.exists)
        XCTAssertTrue(app.buttons["settings-preferences-apply"].exists)
        cancel.click()
        XCTAssertTrue(review.waitForDisappearance(timeout: 5))
        try FileManager.default.removeItem(at: output)
        export.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { FileManager.default.fileExists(atPath: output.path) })
        XCTAssertEqual(try settings(at: output) as NSDictionary, before as NSDictionary, "cancel must not mutate")

        importButton.click()
        XCTAssertTrue(review.waitForExistenceFast(timeout: 5))
        app.buttons["settings-preferences-apply"].click()
        XCTAssertTrue(review.waitForDisappearance(timeout: 5))
        XCTAssertTrue(app.staticTexts["settings-preferences-status"].waitForExistenceFast(timeout: 5))
        // The sidebar is already mounted. Reading a fresh export alone cannot
        // prove that existing @AppStorage observers received the actual import.
        let translatedCategory = target == "es" ? "General e idioma" : "General & language"
        XCTAssertTrue(app.staticTexts[translatedCategory].waitForExistenceFast(timeout: 5))
        try FileManager.default.removeItem(at: output)
        export.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { FileManager.default.fileExists(atPath: output.path) })
        let after = try settings(at: output)
        XCTAssertEqual(after["interfaceLanguage"] as? String, target)
        XCTAssertEqual(after["vocabulary"] as? String, "Existing, Cóndor, Don’t, C++")
        for key in before.keys where !["interfaceLanguage", "vocabulary"].contains(key) {
            XCTAssertEqual(after[key] as? NSObject, before[key] as? NSObject, key)
        }
        attachScreenshot(of: app, named: "settings-preferences-imported")
    }

    @MainActor
    func testUnsupportedPreferencesRemainRecoverableWithoutMutation() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.json")
        let output = directory.appendingPathComponent("output.json")
        try writeSettings(["globalDictationEnabled": true, "vocabulary": "must-not-apply"], to: input)
        let app = application(input: input, output: output)
        app.launchPortavoz()
        defer { app.terminate() }
        XCTAssertTrue(app.openSettingsCategory("settings-category-data", revealing: "settings-import-preferences"))
        let importButton = app.buttons["settings-import-preferences"]
        importButton.click()
        XCTAssertTrue(app.staticTexts["settings-preferences-status"].waitForExistenceFast(timeout: 5))
        XCTAssertFalse(app.buttons["settings-preferences-apply"].exists)
        app.buttons["settings-export-preferences"].click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { FileManager.default.fileExists(atPath: output.path) })
        XCTAssertEqual(try settings(at: output)["vocabulary"] as? String, "Existing")
        XCTAssertNil(try settings(at: output)["globalDictationEnabled"])

        try writeSettings(["vocabulary": "Recovered"], to: input)
        XCTAssertTrue(importButton.isEnabled)
        importButton.click()
        let review = app.staticTexts["settings-preferences-review"]
        XCTAssertTrue(review.waitForExistenceFast(timeout: 5))
        XCTAssertEqual(renderedText(of: app.staticTexts["settings-preferences-change-vocabulary"]), "Existing, Recovered")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(review.waitForDisappearance(timeout: 5))
        try FileManager.default.removeItem(at: output)
        app.buttons["settings-export-preferences"].click()
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { FileManager.default.fileExists(atPath: output.path) })
        XCTAssertEqual(try settings(at: output)["vocabulary"] as? String, "Existing")
    }

    @MainActor
    private func application(input: URL, output: URL) -> XCUIApplication {
        let app = XCUIApplication.portavoz(openSettings: true)
        app.launchArguments += ["-seed-settings-transfer", "-customVocabulary", "Existing"]
        app.launchEnvironment["PORTAVOZ_UI_TEST_SETTINGS_IMPORT"] = input.path
        app.launchEnvironment["PORTAVOZ_UI_TEST_SETTINGS_EXPORT"] = output.path
        return app
    }

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("settings-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func writeSettings(_ settings: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: ["format": "portavoz-settings", "version": 1, "settings": settings])
            .write(to: url, options: .atomic)
    }

    private func settings(at url: URL) throws -> [String: Any] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(object["settings"] as? [String: Any])
    }
}
