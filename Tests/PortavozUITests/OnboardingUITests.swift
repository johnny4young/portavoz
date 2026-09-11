import XCTest

/// The redesigned first-run onboarding (design system 6a-4): it opens on the
/// live "first listen" instead of a static welcome. These assert the demo
/// step renders and that Skip is always reachable — the live capture itself
/// needs a real microphone, so it's out of XCUITest's reach and never driven.
final class OnboardingUITests: PortavozUITestCase {
    @MainActor
    func testAdvancesFromFirstListenToLocalVoiceEnrollment() {
        let app = XCUIApplication.portavoz(showOnboarding: true)
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
        for _ in 0..<2 {
            app.control(withIdentifier: "onboarding-continue").click()
        }

        XCTAssertTrue(
            app.control(withIdentifier: "onboarding-voice-enroll").waitForExistenceFast(timeout: 5),
            "the optional voice step must offer application-owned enrollment")
        XCTAssertTrue(app.control(withIdentifier: "onboarding-skip").exists)
        attachScreenshot(of: app, named: "onboarding-local-voice-enrollment")
    }
}
