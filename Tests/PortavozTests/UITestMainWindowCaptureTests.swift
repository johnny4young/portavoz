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

    func testCompactPlacementUsesItsOwnAttachedWindowWithoutNativeInput() async {
        let untouched = makeHiddenWindow()
        let originalFrame = untouched.frame
        let window = makeHiddenWindow()
        let screen = NSRect(x: 0, y: 90, width: 1_512, height: 870)
        let capture = UITestMainWindowCaptureView { ownedWindow in
            UITestWindowPlacement.positionMainWindow(
                ownedWindow,
                arguments: ["portavoz-app", "-use-temp-store", "-ui-test-compact-main-window"],
                visibleFrame: screen)
        }
        window.contentView?.addSubview(capture)
        XCTAssertEqual(window.frame, NSRect(x: 400, y: 310, width: 900, height: 650))
        XCTAssertTrue(screen.contains(window.frame))
        XCTAssertEqual(untouched.frame, originalFrame)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(untouched.isVisible)
    }

    func testPresentationRestoresOwnedCompactGeometryAfterInitialAttachment() async {
        let window = makeHiddenWindow()
        let other = makeHiddenWindow()
        let otherFrame = other.frame
        let controller = UITestMainWindowCaptureController { ownedWindow in
            UITestWindowPlacement.positionMainWindow(
                ownedWindow,
                arguments: ["-use-temp-store", "-ui-test-compact-main-window"],
                visibleFrame: NSRect(x: 0, y: 90, width: 1_512, height: 870))
        }
        window.contentView?.addSubview(controller.view)
        let compactFrame = window.frame
        window.setFrame(NSRect(x: 0, y: 90, width: 1_112, height: 870), display: false)
        XCTAssertNotEqual(window.frame, compactFrame)
        controller.viewDidAppear()
        XCTAssertEqual(window.frame, compactFrame)
        XCTAssertEqual(other.frame, otherFrame)
        controller.view.removeFromSuperview()
        controller.viewDidAppear()
        XCTAssertEqual(other.frame, otherFrame, "a detached presentation cannot position another window")
    }

    func testCompactPlacementFitsSmallScreensAndLeavesOrdinaryPlacementUnchanged() async {
        let window = makeHiddenWindow()
        for screen in [
            NSRect(x: 0, y: 50, width: 1_024, height: 674),
            NSRect(x: 0, y: 20, width: 800, height: 600)
        ] {
            UITestWindowPlacement.positionMainWindow(
                window,
                arguments: ["-use-temp-store", "-ui-test-compact-main-window"],
                visibleFrame: screen)
            XCTAssertTrue(screen.contains(window.frame))
            XCTAssertEqual(window.frame.size, NSSize(
                width: min(900, screen.width), height: min(650, screen.height)))
        }
        UITestWindowPlacement.positionMainWindow(
            window, arguments: ["-use-temp-store"],
            visibleFrame: NSRect(x: 0, y: 90, width: 1_512, height: 870))
        XCTAssertEqual(window.frame, NSRect(x: 400, y: 90, width: 1_112, height: 870))
    }

    func testCompactArgumentCannotPositionProductionOrInventAScreen() async {
        let window = makeHiddenWindow()
        let originalFrame = window.frame
        for arguments in [[], ["-ui-test-compact-main-window"], ["-use-temp-store=true"]] {
            UITestWindowPlacement.positionMainWindow(
                window, arguments: arguments,
                visibleFrame: NSRect(x: 0, y: 0, width: 1_512, height: 870))
            XCTAssertEqual(window.frame, originalFrame)
        }
        for screen in [nil, NSRect.zero] as [NSRect?] {
            UITestWindowPlacement.positionMainWindow(
                window, arguments: ["-use-temp-store", "-ui-test-compact-main-window"],
                visibleFrame: screen)
            XCTAssertEqual(window.frame, originalFrame)
        }
    }

    private func makeHiddenWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true)
    }
}
