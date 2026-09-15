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
        let app = try launchOwnedApp(scrollGeometry: true)
        let target = app.buttons["proof-target"]
        let viewport = app.scrollViews["proof-scroll"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        let effects = try XCTUnwrap(ProcessInfo.processInfo.environment["PROOF_EFFECTS_ROOT"])
        let targetEffect = URL(fileURLWithPath: effects).appendingPathComponent("target")
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetEffect.path))
        for scenario in 0..<8 {
            // Both directions: amplified, ordinary, buffered, then dropped input.
            // A previous reveal must not calibrate a later invocation.
            XCTAssertFalse(viewport.frame.contains(target.frame))
            XCTAssertFalse(target.revealVertically(in: viewport, maxScrolls: 0))
            guard target.revealVertically(in: viewport, maxScrolls: 4) else {
                XCTFail("the real helper must reveal the clipped target within its original wheel budget")
                return
            }
            XCTAssertTrue(target.revealVertically(in: viewport, maxScrolls: 0))
            target.click()
            XCTAssertTrue(app.staticTexts["Target action happened"].waitForExistence(timeout: 5))
            XCTAssertEqual(try String(contentsOf: targetEffect, encoding: .utf8), String(scenario + 1))
            if scenario < 7 {
                app.buttons["proof-next-scroll"].click()
                XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 5))
            }
        }
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

    private func launchOwnedApp(scrollGeometry: Bool = false) throws -> XCUIApplication {
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
        app.launchEnvironment["PROOF_SCROLL_GEOMETRY"] = scrollGeometry ? "1" : "0"
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
