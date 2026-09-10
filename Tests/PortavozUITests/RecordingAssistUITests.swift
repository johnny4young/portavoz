import XCTest

final class RecordingAssistUITests: PortavozUITestCase {
    /// The live assist area stacked eight panels inside a 260 pt scroll with an
    /// unbounded card list: one real 18-minute meeting produced 23 cards and
    /// roughly seven screens of scrolling. This proves the replacement (D504):
    /// one open panel at a time, the newest cards open, older ones folded to a
    /// single line, and the question addressed to the user in its own slot.
    @MainActor
    func testLiveAssistKeepsOnePanelOpenAndABoundedCardList() {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            simulateSequoiaCapabilities: true,
            simulateLiveTranscriptBrowsing: true)
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] =
            #"{"companionEnabled":true}"#
        app.launchArguments.append("-seed-live-companion-ui")
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistenceFast(timeout: 15))
        record.click()
        XCTAssertTrue(
            app.waitForLiveTranscriptFrontier(),
            "the assist assertions require closed captions")

        let assist = app.control(withIdentifier: "recording-assist-panel")
        XCTAssertTrue(assist.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(
            app.control(withIdentifier: "recording-assist-divider").exists,
            "the captions/assist split must be adjustable instead of pinned")

        XCTAssertTrue(
            app.control(withIdentifier: "recording-focus-card")
                .waitForExistenceFast(timeout: 10),
            "the one question addressed to the user must sit above the tabs")

        // The newest three stay open; everything older folds to one line and
        // stays reachable.
        XCTAssertTrue(
            app.control(withIdentifier: "recording-companion-card-2")
                .waitForExistenceFast(timeout: 5))
        XCTAssertFalse(
            app.control(withIdentifier: "recording-companion-card-3").exists,
            "the recency window must fold everything past the newest few")
        let folded = app.control(withIdentifier: "recording-companion-folded-3")
        XCTAssertTrue(folded.exists, "older cards stay reachable as one-line rows")
        XCTAssertTrue(
            app.control(withIdentifier: "recording-companion-show-all-0").exists,
            "a clamped answer must offer to open fully rather than run long")

        // Reaching back for an older card folds the oldest recency-open one,
        // so the panel keeps its size instead of growing.
        folded.click()
        XCTAssertTrue(
            app.control(withIdentifier: "recording-companion-card-3")
                .waitForExistenceFast(timeout: 3))
        XCTAssertFalse(
            app.control(withIdentifier: "recording-companion-card-2").exists,
            "opening an older card must close the oldest card open by recency")
        XCTAssertTrue(app.control(withIdentifier: "recording-companion-folded-2").exists)

        // One panel at a time: the Companion list leaves when Notes opens.
        app.openAssistTab("notes")
        XCTAssertFalse(
            app.control(withIdentifier: "recording-companion-card-0")
                .waitForExistenceFast(timeout: 2),
            "only the selected panel may occupy the assist area")
        XCTAssertTrue(
            app.control(withIdentifier: "recording-focus-card").exists,
            "the focus slot survives a tab switch — it is what cannot wait")

        app.openAssistTab("companion")
        XCTAssertTrue(
            app.control(withIdentifier: "recording-companion-card-0")
                .waitForExistenceFast(timeout: 5))
    }
}
