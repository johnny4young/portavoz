import Darwin
import XCTest

/// These negative controls intentionally fail under a separate invocation.
/// The ordinary Portavoz catalog never discovers them or interprets them as
/// product failures. Both use the real shared base's installation call site.
final class InterruptionSafetyTests: PortavozUITestCase {
    private var ownedRoot: URL?

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

    private func launchOwnedApp() throws -> XCUIApplication {
        let directory = try UITestStorage.makeDirectory()
        ownedRoot = directory.deletingLastPathComponent()
        // Only a newly allocated public-synthetic fixture path is recorded.
        print("FIXTURE_SCRATCH=\(directory.path)")
        let app = XCUIApplication()
        try UITestStorage.register(app)
        app.launchEnvironment["PROOF_OVERLAY_EXECUTABLE"] =
            ProcessInfo.processInfo.environment["PROOF_OVERLAY_EXECUTABLE"]
        app.launchEnvironment["PROOF_EFFECTS_ROOT"] =
            ProcessInfo.processInfo.environment["PROOF_EFFECTS_ROOT"]
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        app.launch()
        let arm = app.buttons["proof-arm"]
        XCTAssertTrue(arm.waitForExistence(timeout: 5))
        app.activate()
        return app
    }

    private func exerciseInterruption() throws {
        let app = try launchOwnedApp()
        _ = try armInterruption(app)
        print("FIXTURE_INTERRUPTION_READY")
        app.buttons["proof-target"].click()
        XCTFail("FIXTURE_TARGET_CONTINUED")
    }

    private func armInterruption(_ app: XCUIApplication) throws -> XCUIApplication {
        app.buttons["proof-arm"].click()
        XCTAssertTrue(app.staticTexts["Dialog armed"].waitForExistence(timeout: 5))
        let overlay = XCUIApplication(bundleIdentifier: "app.portavoz.testing.interruption-overlay")
        guard overlay.windows["Synthetic interruption owner"].waitForExistence(timeout: 5) else {
            throw NSError(domain: "FIXTURE_NOT_READY", code: 1)
        }
        return overlay
    }
}
