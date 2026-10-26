import AppKit
import XCTest

@testable import portavoz_app

final class DictationPanelAnchorTests: XCTestCase {
    private let visible = NSRect(x: 0, y: 40, width: 1_440, height: 860)
    private let size = NSSize(width: 176, height: 32)

    func testTheStripOpensJustBelowTheCaret() {
        let caret = NSRect(x: 600, y: 500, width: 2, height: 18)
        let origin = DictationPanelAnchor.origin(for: size, near: .caret(caret), in: visible)
        XCTAssertEqual(origin, NSPoint(x: 584, y: 500 - 8 - 32))
    }

    func testNearTheBottomItOpensAboveAndAtTheEdgeItStaysOnScreen() {
        let low = NSRect(x: 1_420, y: 50, width: 2, height: 18)
        let origin = DictationPanelAnchor.origin(for: size, near: .caret(low), in: visible)
        XCTAssertEqual(origin.y, 50 + 18 + 8, "no room below, so above the caret")
        XCTAssertEqual(origin.x, visible.maxX - size.width, "never past the right edge")

        let corner = DictationPanelAnchor.origin(for: size, near: .pointer(NSPoint(x: -30, y: 2_000)), in: visible)
        XCTAssertTrue(visible.contains(NSRect(origin: corner, size: size)), "always fully visible")
    }

    func testThePointerLeavesRoomForTheCursorGlyph() {
        let origin = DictationPanelAnchor.origin(for: size, near: .pointer(NSPoint(x: 300, y: 400)), in: visible)
        XCTAssertEqual(origin, NSPoint(x: 284, y: 400 - 20 - 8 - 32))
    }

    func testAccessibilityGeometryFlipsToCocoaCoordinates() {
        let rect = DictationPanelAnchor.cocoaRect(
            fromAccessibility: CGRect(x: 100, y: 200, width: 2, height: 18), primaryScreenHeight: 900)
        XCTAssertEqual(rect, NSRect(x: 100, y: 900 - 218, width: 2, height: 18))
    }
}

@MainActor
extension DictationControllerTests {
    func testTheStripAnchorIsReadWithTheDestination() async {
        let harness = DictationControllerHarness(text: "Send the report.")
        defer { harness.controller.cancel() }
        harness.controller.toggle(using: harness.dependencies)
        XCTAssertNil(harness.controller.panelAnchor, "disposable launches keep the default placement")
        harness.controller.cancel()

        var dependencies = harness.dependencies
        dependencies.locatePanelAnchor = { .pointer(NSPoint(x: 300, y: 400)) }
        harness.controller.toggle(using: dependencies)
        XCTAssertEqual(harness.controller.panelAnchor, .pointer(NSPoint(x: 300, y: 400)))
    }
}
