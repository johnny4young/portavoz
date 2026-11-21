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

    func testCompactFixtureFrameStaysInsideTheVisibleScreen() async {
        for visible in [
            NSRect(x: 0, y: 25, width: 1_512, height: 886),
            NSRect(x: 0, y: 25, width: 1_024, height: 768),
            NSRect(x: 0, y: 25, width: 900, height: 560)
        ] {
            let normal = UITestWindowPlacement.mainWindowFrame(
                in: visible, preferredHeight: nil)
            let compact = UITestWindowPlacement.mainWindowFrame(
                in: visible, preferredHeight: 620)
            let minimum = UITestWindowPlacement.mainWindowFrame(
                in: visible, preferredHeight: 560)
            XCTAssertEqual(normal.height, visible.height)
            XCTAssertEqual(compact.height, min(visible.height, 620))
            XCTAssertEqual(minimum.height, min(visible.height, 560))
            XCTAssertTrue(visible.contains(normal))
            XCTAssertTrue(visible.contains(compact))
            XCTAssertTrue(visible.contains(minimum))
            XCTAssertGreaterThanOrEqual(compact.width, 900)
            let wide = UITestWindowPlacement.mainWindowFrame(
                in: visible, preferredHeight: nil, fullWidth: true)
            XCTAssertEqual(wide, visible)
        }
    }

    func testOnlyAResetDisposableLaunchForgetsTheSidebar() async throws {
        let suite = "portavoz-split-view-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView"
        defaults.set(["collapsed"], forKey: key)
        defaults.set("kept", forKey: "other")

        for arguments in [["Portavoz"], ["Portavoz", "-reset-sidebar"], ["Portavoz", "-use-temp-store"]] {
            UITestWindowPlacement.forgetSplitViewFrames(arguments: arguments, defaults: defaults)
            XCTAssertNotNil(defaults.object(forKey: key), "\(arguments) must keep the saved sidebar")
        }
        UITestWindowPlacement.forgetSplitViewFrames(
            arguments: ["Portavoz", "-use-temp-store", "-reset-sidebar"], defaults: defaults)
        XCTAssertNil(defaults.object(forKey: key))
        XCTAssertEqual(defaults.string(forKey: "other"), "kept")
    }

    func testMenuFixtureFramePreservesTopAlignmentOnOffsetScreens() async {
        for screen in [NSRect(x: 0, y: 25, width: 1_512, height: 870),
                       NSRect(x: -1_440, y: -200, width: 1_440, height: 900),
                       NSRect(x: 0, y: 25, width: 1_280, height: 550)] {
            let frame = UITestWindowPlacement.mainWindowFrame(in: screen, preferredHeight: 560)
            XCTAssertEqual(frame.maxY, screen.maxY)
            XCTAssertEqual(frame.height, min(560, screen.height))
            XCTAssertTrue(screen.contains(frame))
        }
    }

    private func makeHiddenWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true)
    }
}
