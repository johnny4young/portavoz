import AppKit
import XCTest

final class AutomationUITests: XCTestCase {
    @MainActor
    func testRecordURLRoutesIntoAVisibleRecording() async throws {
        let app = XCUIApplication.portavoz(simulateLiveTranscriptionAttach: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let process = try XCTUnwrap(
            NSWorkspace.shared.frontmostApplication,
            "the launched disposable app must be the frontmost application")
        XCTAssertEqual(
            process.bundleIdentifier,
            "app.portavoz.mac",
            "the exact disposable Portavoz app must receive the external route")
        let bundleURL = try XCTUnwrap(
            process.bundleURL,
            "the launched disposable app must expose its exact bundle URL")
        let recordURL = try XCTUnwrap(URL(string: "portavoz://record"))

        let opened = await withCheckedContinuation { continuation in
            NSWorkspace.shared.open(
                [recordURL],
                withApplicationAt: bundleURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                continuation.resume(returning: error == nil)
            }
        }

        XCTAssertTrue(opened, "LaunchServices must deliver the production recording URL")
        XCTAssertTrue(
            app.control(withIdentifier: "recording-catch-up")
                .waitForExistence(timeout: 10),
            "the external route must enter a visible, active recording")
        XCTAssertTrue(
            app.control(withIdentifier: "recording-mute-mic").exists,
            "the externally started recording must expose its live controls")
        let elapsedTime = app.control(withIdentifier: "recording-elapsed-time")
        XCTAssertTrue(
            elapsedTime.waitForExistence(timeout: 5),
            "the externally started recording must expose its elapsed time")
        XCTAssertGreaterThan(
            elapsedTime.frame.width,
            elapsedTime.frame.height * 1.5,
            "the elapsed time must remain a horizontal, single-line clock")
        let stop = app.control(withIdentifier: "recording-stop")
        XCTAssertTrue(
            stop.waitForExistence(timeout: 5) && stop.isHittable,
            "Stop must remain visible and interactive in the minimum-width recording layout")
        let window = app.windows.firstMatch
        XCTAssertLessThanOrEqual(
            stop.frame.maxX,
            window.frame.maxX,
            "the responsive recording controls must keep Stop inside the window")
        attachScreenshot(of: app, named: "automation-visible-recording")
    }
}
