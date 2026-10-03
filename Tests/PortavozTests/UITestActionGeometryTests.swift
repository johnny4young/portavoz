import Foundation
import XCTest

final class UITestActionGeometryTests: XCTestCase {
    func testObservedCentreRetainsNegativeDisplayCoordinatesAndSubpixels() throws {
        let offset = try XCTUnwrap(uiPointerOffset(
            target: CGRect(x: -630.25, y: -415.5, width: 40.5, height: 21),
            anchor: CGRect(x: -800, y: -600, width: 640, height: 480)))
        XCTAssertEqual(offset.dx, 190)
        XCTAssertEqual(offset.dy, 195)
    }

    func testInvalidGeometryOnEitherSideNeverProducesAPointer() {
        let valid = CGRect(x: 20, y: 30, width: 100, height: 40)
        let invalid: [CGRect] = [
            .null, .infinite, .zero,
            CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
            CGRect(x: 0, y: CGFloat.infinity, width: 1, height: 1),
            CGRect(x: 0, y: 0, width: CGFloat.nan, height: 1),
            CGRect(x: 0, y: 0, width: 1, height: CGFloat.infinity),
            CGRect(x: 0, y: 0, width: -1, height: 1),
            CGRect(x: 0, y: 0, width: 1, height: -1),
            CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 1)
        ]
        for frame in invalid {
            XCTAssertNil(uiPointerOffset(target: frame, anchor: valid))
            XCTAssertNil(uiPointerOffset(target: valid, anchor: frame))
        }
    }

    func testFiniteFramesWhoseRelativeOffsetOverflowsAreRefused() {
        let magnitude = CGFloat.greatestFiniteMagnitude
        XCTAssertNil(uiPointerOffset(
            target: CGRect(x: magnitude * 0.75, y: 0, width: 1, height: 1),
            anchor: CGRect(x: -magnitude * 0.75, y: 0, width: 1, height: 1)))
    }
}
