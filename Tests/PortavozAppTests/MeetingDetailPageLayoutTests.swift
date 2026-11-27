import SwiftUI
import XCTest

@testable import portavoz_app

final class MeetingDetailPageLayoutTests: XCTestCase {
    private let heights: [CGFloat] = [400, 220, 1_000]

    func testWideDetailPutsTheMarginBesideTheReadingColumn() {
        let frames = MeetingDetailPageMetrics.frames(width: 1_000, count: 3) { index, _ in heights[index] }

        XCTAssertEqual(frames[1].width, 291.6, accuracy: 0.5, "the margin is about 300 points")
        XCTAssertEqual(frames[1].minY, 0, "the margin starts level with the standfirst")
        XCTAssertEqual(frames[0].width, MeetingDetailPageMetrics.readingWidth(forPageWidth: 1_000))
        XCTAssertEqual(frames[0].width + MeetingDetailPageMetrics.gap + frames[1].width, 1_000, accuracy: 0.5)
        XCTAssertEqual(frames[2].width, 1_000, "the transcript spans the page so its notes reach the margin")
        XCTAssertEqual(frames[2].minY, 400 + MeetingDetailPageMetrics.sectionSpacing, "it starts under the material, not the margin")
        XCTAssertGreaterThan(frames[1].minX, frames[0].maxX)
    }

    func testANotedTranscriptStartsBelowATallerMargin() {
        let heights: [CGFloat] = [200, 520, 1_000]
        let frames = MeetingDetailPageMetrics.frames(
            width: 1_000, count: 3, transcriptHoldsMarginNotes: true
        ) { index, _ in heights[index] }

        XCTAssertEqual(frames[1].maxY, 520)
        XCTAssertEqual(
            frames[2].minY, 520 + MeetingDetailPageMetrics.sectionSpacing,
            "margin notes sit level with their lines, so no line starts beside the margin's own content")
    }

    func testANotedTranscriptStaysUnderMaterialTallerThanTheMargin() {
        let frames = MeetingDetailPageMetrics.frames(
            width: 1_000, count: 3, transcriptHoldsMarginNotes: true
        ) { index, _ in heights[index] }

        XCTAssertEqual(frames[2].minY, 400 + MeetingDetailPageMetrics.sectionSpacing)
    }

    func testATranscriptWithoutNotesReadsBesideATallerMargin() {
        let heights: [CGFloat] = [200, 520, 1_000]
        let frames = MeetingDetailPageMetrics.frames(width: 1_000, count: 3) { index, _ in heights[index] }

        XCTAssertEqual(frames[2].minY, 200 + MeetingDetailPageMetrics.sectionSpacing)
    }

    func testNarrowDetailReadsAsOneColumnWithTheMarginBeforeTheTranscript() {
        let frames = MeetingDetailPageMetrics.frames(width: 560, count: 3) { index, _ in heights[index] }

        XCTAssertNil(MeetingDetailPageMetrics.marginWidth(forPageWidth: 560))
        XCTAssertEqual(MeetingDetailPageMetrics.readingWidth(forPageWidth: 560), 560)
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

    func testANotedLineKeepsTheReadingColumnAndPutsItsNotesInTheMargin() {
        let arrangement = MeetingDetailPageMetrics.lineArrangement(
            width: 1_024, overhang: 12, hasNotes: true, foldedInsets: EdgeInsets()
        ) { index, _ in index == 0 ? 80 : 200 }
        let margin = MeetingDetailPageMetrics.marginWidth(forPageWidth: 1_000)

        XCTAssertEqual(arrangement.frames[0].width, MeetingDetailPageMetrics.readingWidth(forPageWidth: 1_000) + 24)
        XCTAssertEqual(arrangement.frames[1].width, margin)
        XCTAssertEqual(arrangement.frames[1].minY, 0, "the notes sit level with their line")
        XCTAssertEqual(arrangement.frames[1].maxX, 1_012, accuracy: 0.001, "the notes end on the page edge")
        XCTAssertEqual(arrangement.height, 200)
    }

    func testANarrowPageFoldsTheNotesUnderTheirLine() {
        let insets = EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 48)
        let arrangement = MeetingDetailPageMetrics.lineArrangement(
            width: 628, overhang: 12, hasNotes: true, foldedInsets: insets
        ) { index, _ in index == 0 ? 80 : 200 }

        XCTAssertEqual(arrangement.frames[0].width, 628, "without a margin the line spans the row")
        XCTAssertEqual(arrangement.frames[1], CGRect(x: 12, y: 84, width: 568, height: 200))
        XCTAssertEqual(arrangement.height, 292)
    }

    func testALineReadsOnlyTheWidthItIsGiven() {
        for width in stride(from: CGFloat(500), through: 1_400, by: 0.5) {
            let first = MeetingDetailPageMetrics.lineArrangement(
                width: width, overhang: 12, hasNotes: true, foldedInsets: EdgeInsets()
            ) { _, width in width / 3 }
            let again = MeetingDetailPageMetrics.lineArrangement(
                width: max(first.frames.map(\.maxX).max() ?? 0, width), overhang: 12, hasNotes: true,
                foldedInsets: EdgeInsets()
            ) { _, width in width / 3 }
            XCTAssertEqual(first, again, "laying a row out at its own extent changes nothing (\(width))")
        }
    }
}
