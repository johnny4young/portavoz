import XCTest

@testable import portavoz_app

final class MeetingDetailPageLayoutTests: XCTestCase {
    private let heights: [CGFloat] = [400, 220, 1_000]

    func testWideDetailPutsTheMarginBesideTheReadingColumn() {
        let frames = MeetingDetailPageMetrics.frames(width: 1_000, count: 3) { index, _ in heights[index] }

        XCTAssertEqual(frames[1].width, 291.6, accuracy: 0.5, "the margin is about 300 points")
        XCTAssertEqual(frames[1].minY, 0, "the margin starts level with the standfirst")
        XCTAssertEqual(frames[0].width, frames[2].width, "material and transcript share the reading column")
        XCTAssertEqual(frames[0].width + MeetingDetailPageMetrics.gap + frames[1].width, 1_000, accuracy: 0.5)
        XCTAssertEqual(frames[2].minY, 400 + MeetingDetailPageMetrics.sectionSpacing)
        XCTAssertGreaterThan(frames[1].minX, frames[0].maxX)
    }

    func testNarrowDetailReadsAsOneColumnWithTheMarginBeforeTheTranscript() {
        let frames = MeetingDetailPageMetrics.frames(width: 560, count: 3) { index, _ in heights[index] }

        XCTAssertNil(MeetingDetailPageMetrics.marginWidth(forPageWidth: 560))
        XCTAssertTrue(frames.allSatisfy { $0.minX == 0 && $0.width == 560 }, "nothing takes width from the column")
        XCTAssertLessThan(frames[0].maxY, frames[1].minY)
        XCTAssertLessThan(frames[1].maxY, frames[2].minY)
    }

    func testTheReadingColumnNeverStarvesForTheMargin() {
        for width in stride(from: CGFloat(500), through: 1_400, by: 10) {
            guard let margin = MeetingDetailPageMetrics.marginWidth(forPageWidth: width) else { continue }
            XCTAssertGreaterThanOrEqual(width - margin - MeetingDetailPageMetrics.gap, MeetingDetailPageMetrics.minimumMainWidth)
            XCTAssertTrue(MeetingDetailPageMetrics.marginRange.contains(margin))
        }
        XCTAssertNotNil(MeetingDetailPageMetrics.marginWidth(forPageWidth: 1_108), "a full-width window shows the margin")
    }

    func testAnEmptySectionAddsNoSpacing() {
        let frames = MeetingDetailPageMetrics.frames(width: 560, count: 3) { index, _ in index == 0 ? 0 : 100 }

        XCTAssertEqual(frames[1].minY, 0, "no material leaves no gap above the margin")
        XCTAssertEqual(frames[2].minY, 100 + MeetingDetailPageMetrics.sectionSpacing)
    }
}
