import XCTest

final class SpikeHostCrashUITests: PortavozUITestCase {
    @MainActor
    func testForcedHostCrashFailsTheRun() throws {
        let app = try XCUIApplication.portavoz()
        app.launchArguments.append("-spike-force-crash")
        app.launchPortavoz()
        defer { finishUITestApplication(app) }
        XCTAssertTrue(app.buttons["library-new-recording-button"].waitForExistenceFast(timeout: 15))
        Thread.sleep(forTimeInterval: 10)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.buttons["library-new-recording-button"].waitForExistenceFast(timeout: 5))
    }
}
