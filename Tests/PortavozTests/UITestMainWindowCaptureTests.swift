import AppKit
import XCTest

@testable import portavoz_app

@MainActor
final class UITestMainWindowCaptureTests: XCTestCase {
    func testCapturePositionsOnlyItsOwnWindowAndFollowsReparenting() async {
        let first = makeHiddenWindow()
        let second = makeHiddenWindow()
        var positioned: [NSWindow] = []
        let capture = UITestMainWindowCaptureView { positioned.append($0) }

        first.contentView?.addSubview(capture)
        XCTAssertEqual(positioned.count, 1)
        XCTAssertTrue(positioned.first === first)
        capture.viewDidMoveToWindow()
        XCTAssertEqual(positioned.count, 1, "unchanged ownership must not reposition")

        capture.removeFromSuperview()
        XCTAssertEqual(positioned.count, 1, "detaching must not position another window")
        second.contentView?.addSubview(capture)
        XCTAssertEqual(positioned.count, 2)
        XCTAssertTrue(positioned.last === second)
        XCTAssertFalse(first.isVisible)
        XCTAssertFalse(second.isVisible)
    }

    func testUnattachedCaptureDoesNotInventAnAppWindow() async {
        var positions = 0
        let capture = UITestMainWindowCaptureView { _ in positions += 1 }
        capture.viewDidMoveToWindow()
        XCTAssertEqual(positions, 0)
        XCTAssertNil(capture.window)
    }

    func testAcceptedDisposablePanelsShareTheElevatedWindowLevel() async {
        XCTAssertEqual(UITestWindowPlacement.floatingPanelLevel(
            arguments: ["portavoz-app", "-use-temp-store"],
            environment: ["PORTAVOZ_UI_TEST_ALLOW_NOTIFICATION_CENTER_ALERTS": "true"]),
            .statusBar)
    }

    func testProductionAndUnacceptedPanelsRetainTheirFloatingLevel() async {
        let key = "PORTAVOZ_UI_TEST_ALLOW_NOTIFICATION_CENTER_ALERTS"
        XCTAssertEqual(UITestWindowPlacement.floatingPanelLevel(
            arguments: ["portavoz-app"], environment: [key: "true"]), .floating)
        for value in [nil, "false", "TRUE", "1", ""] as [String?] {
            let environment = value.map { [key: $0] } ?? [:]
            XCTAssertEqual(UITestWindowPlacement.floatingPanelLevel(
                arguments: ["portavoz-app", "-use-temp-store"],
                environment: environment), .floating)
        }
    }

    private func makeHiddenWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true)
    }
}
