import XCTest

/// The redesigned first-run onboarding (design system 6a-4): it opens on the
/// live "first listen" instead of a static welcome. These assert the demo
/// step renders and that Skip is always reachable — the live capture itself
/// needs a real microphone, so it's out of XCUITest's reach and never driven.
final class OnboardingUITests: PortavozUITestCase {
    @MainActor
    func testAdvancesFromFirstListenToLocalVoiceEnrollment() throws {
        let app = try XCUIApplication.portavoz(showOnboarding: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "onboarding-first-listen").waitForExistenceFast(timeout: 15),
            "onboarding must open on the first-listen step")
        XCTAssertTrue(
            app.control(withIdentifier: "onboarding-first-listen-button").exists,
            "the first-listen step must offer the Listen button")
        // The escape hatch is always present — onboarding never traps the user.
        XCTAssertTrue(app.control(withIdentifier: "onboarding-skip").exists)

        // Continue leaves the demo without ever recording (permissions next).
        app.control(withIdentifier: "onboarding-continue").click()
        let firstListen = app.control(withIdentifier: "onboarding-first-listen")
        XCTAssertTrue(
            firstListen.waitForDisappearance(timeout: 2),
            "Continue must move off the first-listen step")
        XCTAssertTrue(
            app.control(withIdentifier: "onboarding-during-meeting").waitForExistenceFast(timeout: 5),
            "the second step must introduce Apuntador, Radar and Automations")
        XCTAssertTrue(app.control(withIdentifier: "onboarding-apuntador-toggle").exists)
        XCTAssertTrue(app.control(withIdentifier: "onboarding-example-card").exists)
        for _ in 0..<3 {
            app.control(withIdentifier: "onboarding-continue").click()
        }

        XCTAssertTrue(
            app.control(withIdentifier: "onboarding-voice-enroll").waitForExistenceFast(timeout: 5),
            "the optional voice step must offer application-owned enrollment")
        XCTAssertTrue(app.control(withIdentifier: "onboarding-skip").exists)
        attachScreenshot(of: app, named: "onboarding-local-voice-enrollment")
    }

    @MainActor
    func testModelFailureCanContinueBackAndRetryWithoutDownloading() throws {
        let app = try XCUIApplication.portavoz(showOnboarding: true)
        app.launchArguments.append("-simulate-onboarding-model-recovery")
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.control(withIdentifier: "onboarding-first-listen").waitForExistenceFast(timeout: 15))
        for _ in 0..<3 {
            app.control(withIdentifier: "onboarding-continue").click()
        }
        app.control(withIdentifier: "onboarding-models-download").click()
        let failure = app.control(withIdentifier: "onboarding-models-error")
        XCTAssertTrue(failure.waitForExistenceFast(timeout: 5))
        let expectedFailure = UITestLocale.environmentLocale == "es"
            ? "No se pudieron descargar los modelos. Comprueba la conexión e inténtalo de nuevo."
            : "Models could not be downloaded. Check your connection and try again."
        XCTAssertEqual(renderedText(of: failure), expectedFailure)
        XCTAssertTrue(app.control(withIdentifier: "onboarding-models-retry").exists)
        XCTAssertTrue(app.control(withIdentifier: "onboarding-skip").exists)
        attachScreenshot(of: app, named: "onboarding-model-recovery")

        app.control(withIdentifier: "onboarding-models-continue-without").click()
        XCTAssertTrue(app.control(withIdentifier: "onboarding-voice-enroll").waitForExistenceFast(timeout: 5))
        app.control(withIdentifier: "onboarding-back").click()
        XCTAssertTrue(failure.waitForExistenceFast(timeout: 5))
        app.control(withIdentifier: "onboarding-models-retry").click()
        XCTAssertTrue(app.control(withIdentifier: "onboarding-models-ready").waitForExistenceFast(timeout: 5))
        XCTAssertFalse(failure.exists)
        XCTAssertFalse(app.control(withIdentifier: "onboarding-models-download").exists)
        app.control(withIdentifier: "onboarding-back").click()
        app.control(withIdentifier: "onboarding-continue").click()
        XCTAssertTrue(app.control(withIdentifier: "onboarding-models-ready").waitForExistenceFast(timeout: 5))
        app.control(withIdentifier: "onboarding-continue").click()
        XCTAssertTrue(app.control(withIdentifier: "onboarding-voice-enroll").waitForExistenceFast(timeout: 5))
        app.control(withIdentifier: "onboarding-skip").click()
        XCTAssertTrue(app.control(withIdentifier: "onboarding-skip").waitForDisappearance(timeout: 5))
    }

}
