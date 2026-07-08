import XCTest

/// Drives a seeded meeting to verify the detail view renders — the
/// automated stand-in for eyeballing it. Launches with `-seed-demo` so the
/// library has one deterministic meeting with a transcript, a summary, and
/// a coauthoring bullet (D28).
final class MeetingDetailUITests: XCTestCase {
    @MainActor
    func testSeededMeetingShowsTranscriptAndCoauthoringBullet() {
        let app = XCUIApplication()
        app.launchArguments = ["-use-temp-store", "-seed-demo"]
        app.launch()
        defer { app.terminate() }

        // The seeded meeting appears in the sidebar; open it.
        let meeting = app.staticTexts["Reunión de prueba"]
        XCTAssertTrue(
            meeting.waitForExistence(timeout: 15), "the seeded meeting must appear in the library")
        meeting.click()

        // The transcript rendered (this line is unique to the transcript).
        XCTAssertTrue(
            app.staticTexts["Revisemos el presupuesto de transcripción."]
                .waitForExistence(timeout: 10),
            "the detail view must render the seeded transcript")

        // The summary rendered (its overview is unique to the summary block).
        XCTAssertTrue(
            app.staticTexts["El equipo revisó el presupuesto y fijó el rollout."]
                .waitForExistence(timeout: 10),
            "the summary block must render")

        // The D28 coauthoring marker: only the note-derived bullet carries "▸".
        XCTAssertTrue(
            app.staticTexts["▸"].waitForExistence(timeout: 5),
            "a bullet born from a user note must render its ▸ coauthoring marker")
    }
}
