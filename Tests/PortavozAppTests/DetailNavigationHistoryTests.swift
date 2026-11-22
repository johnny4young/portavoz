import PortavozCore
import XCTest
@testable import portavoz_app

final class DetailNavigationHistoryTests: XCTestCase {
    private let first = Route.meeting(MeetingID(rawValue: UUID()))
    private let second = Route.meeting(MeetingID(rawValue: UUID()))
    private let always: (Route) -> Bool = { _ in true }

    func testBackAndForwardWalkTheRecordedRoutes() {
        var history = DetailNavigationHistory()
        history.record(from: nil, to: first)
        history.record(from: first, to: second)

        XCTAssertEqual(history.step(.back, from: second, isAvailable: always), first)
        history.record(from: second, to: first)
        XCTAssertEqual(history.forward, [second], "stepping back is not a new navigation")
        XCTAssertEqual(history.step(.forward, from: first, isAvailable: always), second)
        history.record(from: first, to: second)
        XCTAssertEqual(history.back, [.library, first])
        XCTAssertEqual(history.forward, [])
    }

    func testANewDestinationClearsForward() {
        var history = DetailNavigationHistory()
        history.record(from: nil, to: first)
        _ = history.step(.back, from: first, isAvailable: always)
        history.record(from: first, to: nil)
        history.record(from: nil, to: .ask)

        XCTAssertEqual(history.forward, [])
        XCTAssertEqual(history.back, [.library])
    }

    func testBackSkipsDestinationsThatNoLongerExist() {
        var history = DetailNavigationHistory()
        history.record(from: nil, to: first)
        history.record(from: first, to: second)
        let deleted: (Route) -> Bool = { $0 != self.first }

        XCTAssertEqual(history.step(.back, from: second, isAvailable: deleted), .library)
        XCTAssertEqual(history.forward, [second])
    }

    func testOriginIsTheNearestSectionBeforeTheMeeting() {
        var history = DetailNavigationHistory()
        XCTAssertEqual(history.origin.section, .today, "a meeting opened at launch comes from Today")
        let focused = Route.commitments(.person(PersonID(rawValue: UUID())))
        history.record(from: nil, to: focused)
        history.record(from: focused, to: first)
        history.record(from: first, to: second)

        XCTAssertEqual(history.origin.section, .radar, "another meeting is not a section")
        XCTAssertEqual(history.origin.route, focused, "the crumb reopens Radar with its focus")
        XCTAssertEqual(Route.commitments(nil).section, .radar)
        XCTAssertNil(Route.recording(nil).section)
    }

    func testHistoryKeepsTheLatestDestinations() {
        var history = DetailNavigationHistory()
        var current: Route = .library
        for _ in 0..<(DetailNavigationHistory.limit + 10) {
            let next = Route.meeting(MeetingID(rawValue: UUID()))
            history.record(from: current, to: next)
            current = next
        }
        XCTAssertEqual(history.back.count, DetailNavigationHistory.limit)
    }

    @MainActor
    func testTheModelSkipsDeletedMeetingsWhenEnablingBack() async {
        let navigation = DetailNavigation { $0 != self.first }
        navigation.record(from: nil, to: first)
        navigation.record(from: first, to: second)
        var route: Route? = second
        XCTAssertTrue(navigation.canStep(.back, from: route), "Today is still there")
        navigation.step(.back, route: &route)
        XCTAssertEqual(route, .library, "the deleted meeting is skipped")
        XCTAssertFalse(navigation.canStep(.back, from: route))
        XCTAssertTrue(navigation.canStep(.forward, from: route))
    }

    func testBreadcrumbTitleShrinksOnlyWhenTheRowIsShort() {
        let title = "Kickoff Aurora Suite with the whole platform team"
        let wide = MeetingDetailBreadcrumbLayout(frame: frame(1400, sidebar: true), origin: "Today", title: title)
        let narrow = MeetingDetailBreadcrumbLayout(frame: frame(668, sidebar: true), origin: "Today", title: title)
        let hidden = MeetingDetailBreadcrumbLayout(frame: frame(668, sidebar: false), origin: "Today", title: title)

        XCTAssertEqual(wide.titleWidth, PVTextMetrics.width(title, PVTextMetrics.font(.body, .semibold)))
        XCTAssertLessThan(narrow.titleWidth, wide.titleWidth)
        XCTAssertEqual(hidden.titleWidth, MeetingDetailBreadcrumbLayout.minimumTitle, "traffic lights take the row")
        let unmeasured = MeetingDetailBreadcrumbLayout(frame: PVTitleBar.Frame(), origin: "Today", title: title)
        XCTAssertEqual(unmeasured.titleWidth, wide.titleWidth, "no truncated flash before the first measurement")
    }

    private func frame(_ width: CGFloat, sidebar: Bool) -> PVTitleBar.Frame {
        PVTitleBar.Frame(CGRect(x: sidebar ? 232 : 0, y: 0, width: width, height: 600))
    }
}
