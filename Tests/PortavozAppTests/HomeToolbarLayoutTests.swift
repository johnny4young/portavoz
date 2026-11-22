import XCTest

@testable import portavoz_app

final class HomeToolbarLayoutTests: XCTestCase {
    private let title = "Today"
    private let date = "Wednesday, September 16"
    private let pill = "Automations · 2 to review"

    func testAskTakesTheBoardWidthWhenTheRowIsWide() {
        let layout = HomeToolbarLayout(
            width: 1200, sidebarVisible: true, title: title, date: date, automations: pill)
        XCTAssertEqual(layout.askWidth, HomeToolbarLayout.askWidths.upperBound)
    }

    func testAskShrinksBetweenItsBoundsBeforeFolding() {
        let taken = HomeToolbarLayout.reserved(title: title, date: date, automations: nil, sidebarVisible: true)
        let layout = HomeToolbarLayout(
            width: taken + 280, sidebarVisible: true, title: title, date: date, automations: nil)
        XCTAssertEqual(layout.askWidth, 280)
    }

    func testAskFoldsToItsGlyphRatherThanFallingUnderItsMinimum() {
        XCTAssertNil(HomeToolbarLayout.askWidth(available: HomeToolbarLayout.askWidths.lowerBound - 1))
        XCTAssertEqual(
            HomeToolbarLayout.askWidth(available: HomeToolbarLayout.askWidths.lowerBound),
            HomeToolbarLayout.askWidths.lowerBound)
    }

    func testThePillAndHiddenSidebarControlsCostAskItsRoom() {
        let width: CGFloat = 640
        let plain = HomeToolbarLayout(width: width, sidebarVisible: true, title: title, date: date, automations: nil)
        XCTAssertNotNil(plain.askWidth, "a minimum detail pane holds the field beside the day")
        let withPill = HomeToolbarLayout(
            width: width, sidebarVisible: true, title: title, date: date, automations: pill)
        XCTAssertNil(withPill.askWidth, "the pill keeps its full label; Ask folds")
        let withControls = HomeToolbarLayout(
            width: width, sidebarVisible: false, title: title, date: date, automations: nil)
        XCTAssertNil(withControls.askWidth, "the traffic lights share the row when the sidebar hides")
    }

    func testALongerPillLabelNeedsMoreRoom() {
        XCTAssertGreaterThan(
            HomeToolbarLayout.pillWidth("Automations · 12 to review"), HomeToolbarLayout.pillWidth(pill))
    }
}
