import AppKit
import XCTest

@testable import portavoz_app

@MainActor
final class SettingsWindowCaptureTests: XCTestCase {
    func testPlacementObservesRestorationAfterAttachmentAndBeforeAppearance() async {
        let reference = SettingsWindowReference()
        let window = makeHiddenWindow()
        var frames: [NSRect] = []
        let controller = SettingsWindowCaptureController(reference: reference) {
            frames.append($0.frame)
        }
        window.contentView?.addSubview(controller.view)
        XCTAssertTrue(reference.window === window, "receipt routing needs attachment, not visibility")
        XCTAssertTrue(frames.isEmpty, "initial placement would be overwritten by restoration")

        let restored = NSRect(x: -1_600, y: 170, width: 760, height: 652)
        window.setFrame(restored, display: false)
        controller.viewDidAppear()
        XCTAssertEqual(frames, [restored], "position the restored size, not the attachment frame")

        controller.viewDidDisappear()
        let reopened = NSRect(x: -2_000, y: -200, width: 800, height: 700)
        window.setFrame(reopened, display: false)
        controller.viewDidAppear()
        XCTAssertEqual(frames, [restored, reopened], "reopening must not retain first-presentation geometry")
        XCTAssertFalse(window.isVisible, "unit tests must not open real host windows")
    }

    func testDetachedAndReparentedControllerOnlyPositionsItsCurrentWindow() async {
        let reference = SettingsWindowReference()
        let first = makeHiddenWindow()
        let second = makeHiddenWindow()
        var positioned: [NSWindow] = []
        let controller = SettingsWindowCaptureController(reference: reference) { positioned.append($0) }

        controller.viewDidAppear()
        XCTAssertNil(reference.window)
        XCTAssertTrue(positioned.isEmpty)
        first.contentView?.addSubview(controller.view)
        controller.viewDidAppear()
        XCTAssertTrue(positioned.first === first)
        controller.view.removeFromSuperview()
        controller.viewDidAppear()
        XCTAssertNil(reference.window)
        XCTAssertEqual(positioned.count, 1, "detachment must not reuse the previous window")
        second.contentView?.addSubview(controller.view)
        XCTAssertTrue(reference.window === second)
        controller.viewDidAppear()
        XCTAssertEqual(positioned.count, 2)
        XCTAssertTrue(positioned.last === second)
    }

    func testOrdinaryPresentationPreservesUserFrameAndLevel() async {
        XCTAssertFalse(ProcessInfo.processInfo.arguments.contains("-use-temp-store"))
        let window = makeHiddenWindow()
        let controller = SettingsWindowCaptureController(reference: SettingsWindowReference())
        window.contentView?.addSubview(controller.view)
        let restored = NSRect(x: -1_600, y: 170, width: 760, height: 652)
        window.setFrame(restored, display: false)
        window.level = .floating

        controller.viewDidAppear()

        XCTAssertEqual(window.frame, restored)
        XCTAssertEqual(window.level, .floating)
        XCTAssertFalse(window.isVisible)
    }

    private func makeHiddenWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true)
    }
}
