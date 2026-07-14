import PortavozCore
import XCTest

@testable import IntegrationsKit

final class ChapterExtractorTests: XCTestCase {
    private func segment(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: MeetingID(), channel: .system, text: text,
            startTime: start, endTime: end, isFinal: true)
    }

    func testPauseOpensANewChapterLabeledByFirstSentence() {
        let chapters = ChapterExtractor.chapters(from: [
            segment(0, 5, "Arranquemos con el estado de Zephyr. El cluster corre."),
            segment(6, 10, "Sí, era el cache del provisioning."),
            // A pause past the threshold AND far enough from the last chapter
            // (≥120 s spacing) → a new chapter.
            segment(140, 148, "Cambiando de tema: hablemos del presupuesto Q3."),
        ])
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].startTime, 0)
        XCTAssertEqual(chapters[0].title, "Arranquemos con el estado de Zephyr")
        XCTAssertEqual(chapters[1].startTime, 140)
        XCTAssertEqual(chapters[1].title, "Cambiando de tema: hablemos del presupuesto Q3")
    }

    func testCloselySpacedPausesDoNotOverSegment() {
        // Short turns 30 s apart (like a sparse demo seed): the pauses clear
        // the threshold but not the 120 s min spacing, so it stays one block.
        let segments = (0..<4).map { index in
            segment(Double(index) * 30, Double(index) * 30 + 4, "Turn \(index).")
        }
        XCTAssertTrue(ChapterExtractor.chapters(from: segments).isEmpty)
    }

    func testLongGapFreeStretchStillSplitsAtTheCap() {
        // Contiguous 1-minute segments, no pauses; the 300 s cap forces a
        // split once a chapter runs past five minutes.
        let segments = (0..<8).map { index in
            segment(Double(index) * 60, Double(index) * 60 + 58, "Segment \(index) talking.")
        }
        let chapters = ChapterExtractor.chapters(from: segments)
        XCTAssertGreaterThan(chapters.count, 1)
        XCTAssertEqual(chapters.first?.startTime, 0)
    }

    func testSingleShortMeetingHasNoChapters() {
        let chapters = ChapterExtractor.chapters(from: [
            segment(0, 5, "Quick note."),
            segment(6, 10, "Nothing else."),
        ])
        XCTAssertTrue(chapters.isEmpty, "one chapter is no chapter — the header already says it")
    }

    func testEmptyInput() {
        XCTAssertTrue(ChapterExtractor.chapters(from: []).isEmpty)
    }

    func testFallbackLabelNeverLeaksFromTheNextChapter() {
        let chapters = ChapterExtractor.chapters(from: [
            segment(0, 1, "E"),
            segment(100, 101, "TO"),
            segment(140, 145, "Budget planning starts with the Q3 forecast."),
        ])

        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "E")
        XCTAssertEqual(chapters[1].title, "Budget planning starts with the Q3 forecast")
    }
}
