import XCTest
@testable import portavoz_app

@MainActor
final class LiveAssistUITestFixtureTests: XCTestCase {
    func testLiveFixtureFlagsCannotActivateOutsideTemporaryComposition() async {
        let flags = [
            "-use-temp-store", "-seed-live-companion-ui", "-seed-live-translation-ui",
            "-seed-live-summary-ui", "-seed-live-assist-arrivals-ui", "-simulate-stop-app-intent"
        ]
        XCTAssertNil(LiveAssistUITestFixture(arguments: flags, usesTemporaryStore: false))
        XCTAssertNil(LiveAssistUITestFixture(arguments: [], usesTemporaryStore: false))
    }

    func testTemporaryCompositionStillRequiresExplicitSummaryAndStopFlags() async throws {
        let defaults = try XCTUnwrap(LiveAssistUITestFixture(arguments: [], usesTemporaryStore: true))
        XCTAssertEqual(defaults.summaryInterval, .seconds(40))
        XCTAssertFalse(defaults.simulateStopIntent)
        let fixture = try XCTUnwrap(LiveAssistUITestFixture(
            arguments: ["-seed-live-summary-ui", "-simulate-stop-app-intent"], usesTemporaryStore: true))
        XCTAssertEqual(fixture.summaryInterval, .milliseconds(50))
        XCTAssertTrue(fixture.simulateStopIntent)
    }
}
