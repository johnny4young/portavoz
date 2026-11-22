import XCTest

/// The meeting's title bar: back, forward and the breadcrumb over the window history.
final class MeetingChromeUITests: PortavozUITestCase {
    @MainActor
    func testMeetingToolbarWalksHistoryUnderABreadcrumb() throws {
        let app = try launchShowcaseHeroMeeting(["-seed-wide-window", "-AppleInterfaceStyle", "Light"])
        defer { finishUITestApplication(app) }

        let crumb = app.control(withIdentifier: "detail-breadcrumb-title")
        let hero = "Sprint Demo · Zephyr"
        XCTAssertTrue(waitForUITestCondition(timeout: 10) { renderedText(of: crumb) == hero })
        XCTAssertEqual(renderedText(of: app.control(withIdentifier: "detail-title")), hero, "the title drops its date")
        XCTAssertEqual(renderedText(of: app.buttons["detail-breadcrumb-origin"]), "Today")
        let back = app.buttons["detail-back"]
        let forward = app.buttons["detail-forward"]
        XCTAssertTrue(back.isEnabled)
        XCTAssertFalse(forward.isEnabled)
        attachScreenshot(of: app, named: "pr-meeting-chrome")

        let other = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'library-meeting-' AND identifier != %@", Self.showcaseHero)).firstMatch
        XCTAssertTrue(other.waitForStableFrame(timeout: 5))
        other.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 10) { renderedText(of: crumb) != hero })
        let otherTitle = renderedText(of: crumb)
        XCTAssertNil(otherTitle.range(of: #"^\d{4}-\d{2}-\d{2} "#, options: .regularExpression))

        back.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 10) { renderedText(of: crumb) == hero })
        XCTAssertTrue(waitForUITestCondition(timeout: 5) { forward.isEnabled })
        forward.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 10) { renderedText(of: crumb) == otherTitle })
        back.click()
        XCTAssertTrue(waitForUITestCondition(timeout: 10) { renderedText(of: crumb) == hero })
        back.click()
        XCTAssertTrue(app.staticTexts["home-title"].waitForExistenceFast(timeout: 10))
        XCTAssertFalse(crumb.exists)
    }

    @MainActor
    func testMeetingToolbarFitsTheNarrowDarkWindow() throws {
        let app = try launchShowcaseHeroMeeting(["-seed-narrow-window", "-seed-dark-appearance"])
        defer { finishUITestApplication(app) }

        let crumb = app.control(withIdentifier: "detail-breadcrumb")
        let actions = app.control(withIdentifier: "detail-actions")
        XCTAssertTrue(crumb.waitForStableFrame(timeout: 10))
        XCTAssertTrue(actions.waitForStableFrame(timeout: 5))
        XCTAssertLessThan(crumb.frame.maxX, actions.frame.minX, "the breadcrumb never runs under the actions")
        attachScreenshot(of: app, named: "pr-meeting-chrome-dark")

        let origin = app.buttons["detail-breadcrumb-origin"]
        XCTAssertTrue(origin.waitForStableFrame(timeout: 5))
        origin.click()
        XCTAssertTrue(app.staticTexts["home-title"].waitForExistenceFast(timeout: 10))
    }

    private static let showcaseHero = "library-meeting-5E0C0A5E-0000-4000-8000-000000000001"

    private func launchShowcaseHeroMeeting(_ arguments: [String]) throws -> XCUIApplication {
        let app = try XCUIApplication.portavoz(seedShowcase: true)
        app.launchArguments += arguments
        app.launchPortavoz()
        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        XCTAssertTrue(app.prepareForInteraction())
        let hero = app.descendants(matching: .any).matching(identifier: Self.showcaseHero).firstMatch
        XCTAssertTrue(hero.waitForStableFrame(timeout: 10))
        hero.click()
        return app
    }
}
