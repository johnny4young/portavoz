import AppKit
import XCTest

@testable import portavoz_app

@MainActor
final class UITestMainWindowCaptureTests: XCTestCase {
    func testCapturePositionsOnlyItsOwnWindowAndFollowsReparenting() async {
        let first = makeHiddenWindow()
        let second = makeHiddenWindow()
        var positioned: [NSWindow] = []
        let capture = UITestMainWindowCaptureController { positioned.append($0) }

        first.contentView?.addSubview(capture.view)
        XCTAssertTrue(positioned.isEmpty, "attachment is too early for placement")
        capture.viewDidAppear()
        XCTAssertEqual(positioned.count, 1)
        XCTAssertTrue(positioned.first === first)

        capture.view.removeFromSuperview()
        capture.viewDidAppear()
        XCTAssertEqual(positioned.count, 1, "detaching must not position another window")
        second.contentView?.addSubview(capture.view)
        capture.viewDidAppear()
        XCTAssertEqual(positioned.count, 2)
        XCTAssertTrue(positioned.last === second)
        XCTAssertFalse(first.isVisible)
        XCTAssertFalse(second.isVisible)
    }

    func testUnattachedCaptureDoesNotInventAnAppWindow() async {
        var positions = 0
        let capture = UITestMainWindowCaptureController { _ in positions += 1 }
        capture.viewDidAppear()
        XCTAssertEqual(positions, 0)
        XCTAssertNil(capture.view.window)
    }

    func testAttachmentMustNotPositionBeforeNativeRestoration() async {
        let window = makeHiddenWindow()
        var frames: [NSRect] = []
        let capture = UITestMainWindowCaptureController { frames.append($0.frame) }
        window.contentView?.addSubview(capture.view)
        let restored = NSRect(x: -1_600, y: 170, width: 1_112, height: 870)
        window.setFrame(restored, display: false)
        XCTAssertTrue(frames.isEmpty, "attachment precedes native frame restoration")
        capture.viewDidAppear()
        XCTAssertEqual(frames, [restored], "appearance must observe the restored frame")
        let reopened = NSRect(x: -2_000, y: -200, width: 1_100, height: 700)
        window.setFrame(reopened, display: false)
        capture.viewDidAppear()
        XCTAssertEqual(frames, [restored, reopened], "every presentation uses its current geometry")
        XCTAssertFalse(window.isVisible)
    }

    func testOrdinaryPresentationPreservesUserFrameAndLevel() async {
        XCTAssertFalse(ProcessInfo.processInfo.arguments.contains("-use-temp-store"))
        let window = makeHiddenWindow()
        let capture = UITestMainWindowCaptureController()
        window.contentView?.addSubview(capture.view)
        let restored = NSRect(x: -1_600, y: 170, width: 1_112, height: 870)
        window.setFrame(restored, display: false)
        window.level = .floating
        capture.viewDidAppear()
        XCTAssertEqual(window.frame, restored)
        XCTAssertEqual(window.level, .floating)
        XCTAssertFalse(window.isVisible)
    }

    func testAcceptedDisposablePanelsShareTheElevatedWindowLevel() async {
        XCTAssertEqual(UITestWindowPlacement.floatingPanelLevel(
            arguments: ["portavoz-app", "-use-temp-store"],
            environment: ["PORTAVOZ_UI_TEST_ALLOW_NOTIFICATION_CENTER_ALERTS": "true"]),
            .statusBar)
    }

    func testMenuFixtureUsesTopOfScreenWithoutCoveringBottomPanel() async {
        let screen = NSRect(x: 0, y: 25, width: 1_512, height: 870)
        let frame = UITestWindowPlacement.mainWindowFrame(
            visibleFrame: screen, leftClearance: 400, menuBarFixture: true)
        XCTAssertEqual(frame, NSRect(x: 400, y: 335, width: 1_112, height: 560))
        XCTAssertGreaterThan(frame.minY, screen.minY,
                             "The top fixture must leave a separate bottom panel hit region")
        XCTAssertEqual(UITestWindowPlacement.mainWindowFrame(
            visibleFrame: screen, leftClearance: 400, menuBarFixture: false),
            NSRect(x: 400, y: 25, width: 1_112, height: 870),
            "Other disposable windows retain their full-height geometry")
    }

    func testMenuFixtureStaysWithinShortAndOffsetScreens() async {
        for screen in [NSRect(x: -1_440, y: -200, width: 1_440, height: 900),
                       NSRect(x: 0, y: 25, width: 1_280, height: 550)] {
            let frame = UITestWindowPlacement.mainWindowFrame(
                visibleFrame: screen, leftClearance: 380, menuBarFixture: true)
            XCTAssertEqual(frame.maxY, screen.maxY)
            XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
            XCTAssertEqual(frame.minX, screen.minX + 380)
            XCTAssertEqual(frame.maxX, screen.maxX)
        }
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
