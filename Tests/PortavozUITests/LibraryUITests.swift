import XCTest

/// UI smoke tests (M11 tooling). These launch the real app under XCUITest so
/// we verify the UI renders without driving the screen by hand. Run with
/// `make test-ui`. The app honors `-use-temp-store` so a test run never
/// touches the real library.
final class LibraryUITests: XCTestCase {
    @MainActor
    func testLibraryWindowRenders() {
        let app = XCUIApplication()
        app.launchArguments = ["-use-temp-store"]
        app.launch()
        defer { app.terminate() }

        // The library's primary action is always present on a clean launch.
        XCTAssertTrue(
            app.buttons["Nueva grabación"].waitForExistence(timeout: 15),
            "the library window must render its 'Nueva grabación' button on launch")
    }
}
