import Darwin
import XCTest

/// These negative controls intentionally fail under a separate invocation.
/// The ordinary Portavoz catalog never discovers them or interprets them as
/// product failures. Both use the real shared base's installation call site.
final class InterruptionSafetyTests: PortavozUITestCase {
    private var ownedRoot: URL?
    /// Launching a second synthetic app is fixture preparation, not the
    /// behaviour under test, so it gets a generous readiness budget. No
    /// admission threshold, effect or cleanup requirement changes with it.
    private let readinessTimeout: TimeInterval = 15

    override var keyboardReceiverBundleIdentifier: String { "app.portavoz.testing.interruption-proof" }

    override func setUp() async throws {
        // Earlier in the LIFO stack than the base's guard. Any return from
        // that guard must hit this sentinel, not a system permission choice.
        addUIInterruptionMonitor(withDescription: "Unreachable fallback sentinel") { _ in
            FileHandle.standardError.write(Data("FIXTURE_FALLBACK_REACHED\n".utf8))
            exit(79)
        }
        try await super.setUp()
    }

    override func tearDown() async throws {
        try await super.tearDown()
        if let ownedRoot {
            XCTAssertFalse(FileManager.default.fileExists(atPath: ownedRoot.path))
        }
    }

    func testSynchronousInterruption() throws {
        try exerciseInterruption()
    }

    func testAsynchronousInterruption() async throws {
        await Task.yield()
        try exerciseInterruption()
    }

    func testSynchronousTextInterruption() throws {
        try exerciseInterruption { typeText("proof\n", in: $0) }
    }

    func testAsynchronousTextInterruption() async throws {
        await Task.yield()
        try exerciseInterruption { typeText("proof\n", in: $0) }
    }

    func testSynchronousTraversalInterruption() throws {
        try exerciseInterruption { typeKey(.tab, modifierFlags: [], in: $0) }
    }

    func testAsynchronousTraversalInterruption() async throws {
        await Task.yield()
        try exerciseInterruption { typeKey(.tab, modifierFlags: [], in: $0) }
    }

    func testUninterruptedKeyboardInputAndTeardown() throws {
        let app = try launchOwnedApp()
        let field = app.textFields["proof-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        typeText("The owner's plan", in: app)
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { field.value as? String == "The owner's plan" })
        typeKey("a", modifierFlags: .command, in: app)
        typeText("Mañana: €42", in: app)
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { field.value as? String == "Mañana: €42" })
        typeKey(.tab, modifierFlags: [], in: app)
        XCTAssertEqual(field.value as? String, "Mañana: €42")
    }

    func testSameApplicationModalChoiceIsObservable() throws {
        let app = try launchOwnedApp(sameApplicationModal: true)
        try armSameApplicationModal(app)
        let editor = app.sheets.textFields["proof-modal-editor"]
        editor.click()
        typeText("Owner’s plan", in: app, modalAnchor: "proof-modal-editor")
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { editor.value as? String == "Owner’s plan" })
        app.sheets.buttons["proof-modal-choice"].click()
        let effects = try XCTUnwrap(ProcessInfo.processInfo.environment["PROOF_EFFECTS_ROOT"])
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            FileManager.default.fileExists(atPath: effects + "/modal-choice")
        })
    }

    func testSynchronousSameApplicationModalInterruption() throws {
        try exerciseSameApplicationModalInterruption()
    }

    func testAsynchronousSameApplicationModalInterruption() async throws {
        await Task.yield()
        try exerciseSameApplicationModalInterruption()
    }

    func testSameApplicationModalRejectsBackgroundAnchor() throws {
        let app = try launchOwnedApp(sameApplicationModal: true)
        try armSameApplicationModal(app)
        print("FIXTURE_INTERRUPTION_READY")
        typeText("proof\n", in: app, modalAnchor: "proof-input")
        XCTFail("FIXTURE_TARGET_CONTINUED")
    }

    func testAppModalDialogChoiceIsObservable() throws {
        let app = try launchOwnedApp(appModalDialog: true)
        try armAppModalDialog(app)
        let editor = app.dialogs.textFields["proof-dialog-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "a runModal alert must be exposed as a dialog")
        editor.click()
        typeText("Owner’s plan", in: app, modalAnchor: "proof-dialog-editor")
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { editor.value as? String == "Owner’s plan" })
        app.dialogs.buttons["proof-dialog-choice"].click()
        let effects = try XCTUnwrap(ProcessInfo.processInfo.environment["PROOF_EFFECTS_ROOT"])
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            FileManager.default.fileExists(atPath: effects + "/modal-choice")
        })
    }

    func testSynchronousAppModalDialogInterruption() throws {
        try exerciseAppModalDialogInterruption()
    }

    func testAsynchronousAppModalDialogInterruption() async throws {
        await Task.yield()
        try exerciseAppModalDialogInterruption()
    }

    private func exerciseAppModalDialogInterruption() throws {
        let app = try launchOwnedApp(appModalDialog: true)
        try armAppModalDialog(app)
        print("FIXTURE_INTERRUPTION_READY")
        typeText("proof\n", in: app)
        XCTFail("FIXTURE_TARGET_CONTINUED")
    }

    private func armAppModalDialog(_ app: XCUIApplication) throws {
        app.buttons["proof-arm"].click()
        guard app.dialogs.staticTexts["Synthetic app-modal interruption"]
            .waitForExistence(timeout: readinessTimeout) else {
            throw NSError(domain: "FIXTURE_NOT_READY", code: 3)
        }
    }

    private func exerciseSameApplicationModalInterruption() throws {
        let app = try launchOwnedApp(sameApplicationModal: true)
        try armSameApplicationModal(app)
        print("FIXTURE_INTERRUPTION_READY")
        typeText("proof\n", in: app)
        XCTFail("FIXTURE_TARGET_CONTINUED")
    }

    private func armSameApplicationModal(_ app: XCUIApplication) throws {
        app.buttons["proof-arm"].click()
        guard app.staticTexts["Synthetic modal interruption"]
            .waitForExistence(timeout: readinessTimeout) else {
            throw NSError(domain: "FIXTURE_NOT_READY", code: 2)
        }
    }

    func testUninterruptedActionAndTeardown() throws {
        let app = try launchOwnedApp()
        app.buttons["proof-target"].click()
        XCTAssertTrue(app.staticTexts["Target action happened"].waitForExistence(timeout: 5))
    }

    func testSyntheticChoiceIsObservable() throws {
        let app = try launchOwnedApp()
        let overlay = try armInterruption(app)
        overlay.buttons["proof-choice"].click()
        let effects = try XCTUnwrap(ProcessInfo.processInfo.environment["PROOF_EFFECTS_ROOT"])
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            FileManager.default.fileExists(atPath: effects + "/choice")
        })
    }

    func testUnexpectedNativePickerRejectsTraversal() throws {
        let app = try armNativePicker()
        print("FIXTURE_INTERRUPTION_READY")
        typeKey("g", modifierFlags: [.command, .shift], in: app)
        XCTFail("FIXTURE_TARGET_CONTINUED")
    }

    func testNativePickerRejectsBackgroundAnchor() throws {
        let app = try armNativePicker()
        print("FIXTURE_INTERRUPTION_READY")
        typeKey("g", modifierFlags: [.command, .shift], in: app, modalAnchor: "proof-input")
        XCTFail("FIXTURE_TARGET_CONTINUED")
    }

    func testNativePickerRejectsAncestorAnchor() throws {
        let app = try armNativePicker()
        typeKey("g", modifierFlags: [.command, .shift], in: app, modalAnchor: "open-panel")
        XCTAssertTrue(app.sheets["GoToWindow"].waitForExistence(timeout: 5))
        print("FIXTURE_INTERRUPTION_READY")
        typeText("proof\n", in: app, modalAnchor: "open-panel")
        XCTFail("FIXTURE_TARGET_CONTINUED")
    }

    func testExpectedNativePickerChoiceIsObservable() throws {
        let app = try armNativePicker()
        typeKey("g", modifierFlags: [.command, .shift], in: app, modalAnchor: "open-panel")
        let goTo = app.sheets["GoToWindow"]
        XCTAssertTrue(goTo.waitForExistence(timeout: 5))
        let source = try XCTUnwrap(app.launchEnvironment["PROOF_NATIVE_SOURCE_ROOT"])
        let folder = URL(fileURLWithPath: source).appendingPathComponent("Selection with spaces")
        typeText(folder.path + "/", in: app, modalAnchor: "PathTextField")
        typeKey(.return, modifierFlags: [], in: app, modalAnchor: "GoToWindow")
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { !goTo.exists })
        typeKey("2", modifierFlags: .command, in: app, modalAnchor: "open-panel")
        let picker = app.dialogs["open-panel"]
        // APFS/native AX can decompose the accented filename. Swift equality
        // preserves canonical equivalence without ignoring accents or case.
        let expectedNames: Set<String> = ["Mañana – owner’s plan.txt", "Don’t send 2.txt"]
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            let names = Set(picker.textFields.allElementsBoundByIndex.compactMap { $0.value as? String })
            return names.isSuperset(of: expectedNames)
        })
        typeKey("a", modifierFlags: .command, in: app, modalAnchor: "open-panel")
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { picker.buttons["OKButton"].isEnabled })
        typeKey(.return, modifierFlags: [], in: app, modalAnchor: "open-panel")
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { !picker.exists })
        let effects = try XCTUnwrap(ProcessInfo.processInfo.environment["PROOF_EFFECTS_ROOT"])
        XCTAssertTrue(waitForUITestCondition(timeout: 5) {
            FileManager.default.fileExists(atPath: effects + "/file-choice")
        })
    }

    private func armNativePicker() throws -> XCUIApplication {
        let app = try launchOwnedApp(nativePicker: true)
        app.buttons["proof-arm"].click()
        XCTAssertTrue(app.dialogs["open-panel"].waitForExistence(timeout: 5))
        return app
    }

    private func launchOwnedApp(
        sameApplicationModal: Bool = false,
        appModalDialog: Bool = false,
        nativePicker: Bool = false
    ) throws -> XCUIApplication {
        let directory = try UITestStorage.makeDirectory()
        ownedRoot = directory.deletingLastPathComponent()
        // Only a newly allocated public-synthetic fixture path is recorded.
        print("FIXTURE_SCRATCH=\(directory.path)")
        let app = XCUIApplication()
        try UITestStorage.register(app)
        app.launchEnvironment["PROOF_SAME_APP_MODAL"] = sameApplicationModal ? "1" : "0"
        app.launchEnvironment["PROOF_APP_MODAL_DIALOG"] = appModalDialog ? "1" : "0"
        app.launchEnvironment["PROOF_OVERLAY_EXECUTABLE"] =
            ProcessInfo.processInfo.environment["PROOF_OVERLAY_EXECUTABLE"]
        app.launchEnvironment["PROOF_EFFECTS_ROOT"] =
            ProcessInfo.processInfo.environment["PROOF_EFFECTS_ROOT"]
        if nativePicker {
            let source = directory.appendingPathComponent("Native picker")
            let selection = source.appendingPathComponent("Selection with spaces")
            try FileManager.default.createDirectory(at: selection, withIntermediateDirectories: true)
            for name in ["Mañana – owner’s plan.txt", "Don’t send 2.txt"] {
                try Data("Public fixture".utf8).write(to: selection.appendingPathComponent(name))
            }
            app.launchEnvironment["PROOF_NATIVE_SOURCE_ROOT"] = source.path
        }
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        app.launch()
        let arm = app.buttons["proof-arm"]
        XCTAssertTrue(arm.waitForExistence(timeout: 5))
        app.activate()
        return app
    }

    private func exerciseInterruption(
        action: (XCUIApplication) -> Void = { $0.buttons["proof-target"].click() }
    ) throws {
        let app = try launchOwnedApp()
        _ = try armInterruption(app)
        print("FIXTURE_INTERRUPTION_READY")
        action(app)
        XCTFail("FIXTURE_TARGET_CONTINUED")
    }

    private func armInterruption(_ app: XCUIApplication) throws -> XCUIApplication {
        app.buttons["proof-arm"].click()
        XCTAssertTrue(app.staticTexts["Dialog armed"].waitForExistence(timeout: readinessTimeout))
        let effects = try XCTUnwrap(ProcessInfo.processInfo.environment["PROOF_EFFECTS_ROOT"])
        guard waitForUITestCondition(timeout: readinessTimeout, {
            FileManager.default.fileExists(atPath: effects + "/overlay-ready")
        }) else { throw NSError(domain: "FIXTURE_NOT_READY", code: 1) }
        let overlay = XCUIApplication(bundleIdentifier: "app.portavoz.testing.interruption-overlay")
        guard overlay.windows["Synthetic interruption owner"]
            .waitForExistence(timeout: readinessTimeout) else {
            throw NSError(domain: "FIXTURE_NOT_READY", code: 1)
        }
        return overlay
    }
}
