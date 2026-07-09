import XCTest

/// UI smoke tests (M11 tooling). These launch the real app under XCUITest so
/// we verify the UI renders without driving the screen by hand. Run with
/// `make test-ui`. The app honors `-use-temp-store` so a test run never
/// touches the real library.
final class LibraryUITests: XCTestCase {
    @MainActor
    func testLibraryWindowRendersByIdentifier() {
        let app = XCUIApplication.portavoz()
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(
            record.waitForExistence(timeout: 15),
            "the library window must render its primary action on launch")

        if let locale = UITestLocale.environmentLocale {
            XCTAssertEqual(record.label, locale == "es" ? "Nueva grabación" : "New recording")
        }
    }
}
