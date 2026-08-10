import AppKit
import XCTest

final class AutomationUITests: PortavozUITestCase {
    @MainActor
    func testRecordingAutomationRoutesStartAndStopThroughVisibleApp() async throws {
        let app = XCUIApplication.portavoz(simulateLiveTranscriptionAttach: true)
        app.launchPortavoz()
        defer {
            if app.state != .notRunning {
                app.terminate()
            }
        }

        let process = try XCTUnwrap(
            NSWorkspace.shared.frontmostApplication,
            "the launched disposable app must be the frontmost application")
        XCTAssertEqual(
            process.bundleIdentifier,
            "app.portavoz.mac.uitest-host",
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
        assertVisibleRecording(in: app, route: "URL")
        attachScreenshot(of: app, named: "automation-visible-recording")
        app.terminate()
        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 10),
            "the URL-routed process must terminate before the native intent relaunch")

        let intentApp = XCUIApplication.portavoz(
            simulateLiveTranscriptionAttach: true,
            simulateAppIntent: true)
        intentApp.launchPortavoz()

        assertVisibleRecording(in: intentApp, route: "native intent")
        attachScreenshot(of: intentApp, named: "native-intent-visible-recording")
        intentApp.terminate()
        XCTAssertTrue(
            intentApp.wait(for: .notRunning, timeout: 10),
            "the native Start process must terminate before the Stop proof")

        let stopIntentApp = XCUIApplication.portavoz(
            simulateLiveTranscriptionAttach: true,
            simulateAppIntent: true,
            simulateStopAppIntent: true)
        stopIntentApp.launchPortavoz()
        defer { stopIntentApp.terminate() }

        XCTAssertTrue(
            stopIntentApp.control(withIdentifier: "recording-failure")
                .waitForExistence(timeout: 15),
            "the native Stop handoff must leave active capture and surface the deterministic no-audio recovery")
        XCTAssertFalse(
            stopIntentApp.control(withIdentifier: "recording-stop").exists,
            "Stop must not remain actionable after the intent closes capture")
        let expectedReference = UITestLocale.environmentLocale == "es"
            ? "Referencia del error: recording.stop.no-audio"
            : "Error reference: recording.stop.no-audio"
        XCTAssertTrue(
            stopIntentApp.staticTexts[expectedReference].waitForExistence(timeout: 5),
            "the Stop action must preserve the recording controller's typed recovery")
        attachScreenshot(of: stopIntentApp, named: "native-intent-stop-recovery")
    }

    @MainActor
    private func assertVisibleRecording(
        in app: XCUIApplication,
        route: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            app.control(withIdentifier: "recording-catch-up")
                .waitForExistence(timeout: 10),
            "the \(route) route must enter a visible, active recording",
            file: file,
            line: line)
        XCTAssertTrue(
            app.control(withIdentifier: "recording-mute-mic").exists,
            "the \(route)-started recording must expose its live controls",
            file: file,
            line: line)
        let elapsedTime = app.control(withIdentifier: "recording-elapsed-time")
        XCTAssertTrue(
            elapsedTime.waitForExistence(timeout: 5),
            "the \(route)-started recording must expose its elapsed time",
            file: file,
            line: line)
        XCTAssertGreaterThan(
            elapsedTime.frame.width,
            elapsedTime.frame.height * 1.5,
            "the elapsed time must remain a horizontal, single-line clock",
            file: file,
            line: line)
        let stop = app.control(withIdentifier: "recording-stop")
        XCTAssertTrue(
            stop.waitForExistence(timeout: 5) && stop.isHittable,
            "Stop must remain visible and interactive in the minimum-width recording layout",
            file: file,
            line: line)
        let window = app.windows.firstMatch
        XCTAssertLessThanOrEqual(
            stop.frame.maxX,
            window.frame.maxX,
            "the responsive recording controls must keep Stop inside the window",
            file: file,
            line: line)
    }
}
