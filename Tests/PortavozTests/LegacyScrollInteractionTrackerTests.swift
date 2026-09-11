import AppKit
import XCTest

@testable import portavoz_app

@MainActor
final class LegacyScrollInteractionTrackerTests: XCTestCase {
    func testCoordinatorObservesOnlyItsScrollViewUntilDisconnected() async {
        let ownedScrollView = NSScrollView()
        let unrelatedScrollView = NSScrollView()
        var interactions = 0
        let coordinator = LegacyScrollInteractionTracker.Coordinator {
            interactions += 1
        }
        coordinator.connect(to: ownedScrollView)

        NotificationCenter.default.post(
            name: NSScrollView.didLiveScrollNotification,
            object: unrelatedScrollView)
        XCTAssertEqual(interactions, 0)

        NotificationCenter.default.post(
            name: NSScrollView.didLiveScrollNotification,
            object: ownedScrollView)
        XCTAssertEqual(interactions, 1)

        coordinator.disconnect()
        NotificationCenter.default.post(
            name: NSScrollView.didLiveScrollNotification,
            object: ownedScrollView)
        XCTAssertEqual(interactions, 1)
    }

    func testReconnectStopsObservingThePreviousScrollView() async {
        let previousScrollView = NSScrollView()
        let currentScrollView = NSScrollView()
        var interactions = 0
        let coordinator = LegacyScrollInteractionTracker.Coordinator {
            interactions += 1
        }
        coordinator.connect(to: previousScrollView)
        coordinator.connect(to: currentScrollView)

        NotificationCenter.default.post(
            name: NSScrollView.didLiveScrollNotification,
            object: previousScrollView)
        XCTAssertEqual(interactions, 0)

        NotificationCenter.default.post(
            name: NSScrollView.didLiveScrollNotification,
            object: currentScrollView)
        XCTAssertEqual(interactions, 1)
    }
}
