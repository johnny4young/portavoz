import XCTest

/// The redesigned first-run onboarding (design system 6a-4): it opens on the
/// live "first listen" instead of a static welcome. These assert the demo
/// step renders and that Skip is always reachable — the live capture itself
/// needs a real microphone, so it's out of XCUITest's reach and never driven.
final class OnboardingUITests: XCTestCase {
    @MainActor
    func testOpensOnTheFirstListenStep() {
        let app = XCUIApplication.portavoz(showOnboarding: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "onboarding-first-listen").waitForExistence(timeout: 15),
            "onboarding must open on the first-listen step")
        XCTAssertTrue(
            app.control(withIdentifier: "onboarding-first-listen-button").exists,
            "the first-listen step must offer the Listen button")
        // The escape hatch is always present — onboarding never traps the user.
        XCTAssertTrue(app.control(withIdentifier: "onboarding-skip").exists)
    }

    @MainActor
    func testContinueAdvancesPastTheFirstListen() {
        let app = XCUIApplication.portavoz(showOnboarding: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let firstListen = app.control(withIdentifier: "onboarding-first-listen")
        XCTAssertTrue(firstListen.waitForExistence(timeout: 15))

        // Continue leaves the demo without ever recording (permissions next).
        app.control(withIdentifier: "onboarding-continue").click()
        XCTAssertFalse(
            firstListen.waitForExistence(timeout: 2),
            "Continue must move off the first-listen step")
    }

    @MainActor
    func testVoiceStepOffersLocalEnrollmentWithoutStartingCapture() {
        let app = XCUIApplication.portavoz(showOnboarding: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(
            app.control(withIdentifier: "onboarding-first-listen").waitForExistence(timeout: 15))
        for _ in 0..<3 {
            app.control(withIdentifier: "onboarding-continue").click()
        }

        XCTAssertTrue(
            app.control(withIdentifier: "onboarding-voice-enroll").waitForExistence(timeout: 5),
            "the optional voice step must offer application-owned enrollment")
        XCTAssertTrue(app.control(withIdentifier: "onboarding-skip").exists)
        attachScreenshot(of: app, named: "onboarding-local-voice-enrollment")
    }
}
