import Foundation
import PortavozCore
import XCTest

@testable import ApplicationKit

final class MeetingTranscriptContentTests: XCTestCase {
    private let meetingID = MeetingID()

    func testAcceptedProjectionPreservesStableRowsLanguagesAndChapterTitles() {
        let firstID = id(1)
        let secondID = id(2)
        let first = segment(
            id: firstID,
            start: 0,
            end: 5,
            text: "Hello",
            language: "en")
        let second = segment(
            id: secondID,
            start: 140,
            end: 145,
            text: "Hablemos del presupuesto.",
            language: "es")

        let content = MeetingTranscriptContent.accepted(
            baseTranscriptRevision: 7,
            segments: [second, first],
            chapterTitles: [140: "Presupuesto Q3"])

        XCTAssertEqual(content.baseTranscriptRevision, 7)
        XCTAssertEqual(content.rows.map(\.id), [firstID, secondID])
        XCTAssertEqual(content.rows.map(\.sourceSegmentIDs), [[firstID], [secondID]])
        XCTAssertEqual(content.rows.map(\.language), ["en", "es"])
        XCTAssertEqual(content.chapters.map(\.startTime), [0, 140])
        XCTAssertEqual(content.chapters.map(\.title), ["Hello", "Presupuesto Q3"])
    }

    func testActiveRowLookupPreservesOverlapAndGapBehavior() {
        let longID = id(1)
        let middleID = id(2)
        let latestID = id(3)
        let content = MeetingTranscriptContent(
            baseTranscriptRevision: 1,
            rows: [
                row(id: longID, sourceIDs: [longID], start: 0, end: 100),
                row(id: middleID, sourceIDs: [middleID], start: 10, end: 20),
                row(id: latestID, sourceIDs: [latestID], start: 15, end: 18),
            ],
            chapters: [])

        XCTAssertNil(content.activeRowID(at: -0.1))
        XCTAssertEqual(content.activeRowID(at: 16), latestID)
        XCTAssertEqual(content.activeRowID(at: 19), middleID)
        XCTAssertEqual(content.activeRowID(at: 20), longID)
        XCTAssertEqual(content.activeRowID(at: 25), longID)
        XCTAssertEqual(
            content.activeRowID(at: 101),
            latestID,
            "a gap keeps the last started row active like the released reader")
    }

    func testComposedRowMapsEverySourceAndNavigationConsumesSeekOnce() {
        let firstSource = id(1)
        let secondSource = id(2)
        let composedID = id(9)
        let content = MeetingTranscriptContent(
            baseTranscriptRevision: 4,
            rows: [row(
                id: composedID,
                sourceIDs: [firstSource, secondSource],
                start: 3,
                end: 8)],
            chapters: [])
        var navigation = MeetingTranscriptNavigationState()

        navigation.reveal(
            sourceSegmentID: secondSource,
            at: -3,
            in: content)

        XCTAssertEqual(content.rowID(containingSourceSegmentID: firstSource), composedID)
        XCTAssertEqual(content.rowID(containingSourceSegmentID: secondSource), composedID)
        XCTAssertEqual(navigation.focusedRowID, composedID)
        XCTAssertEqual(navigation.pendingSeek, 0)
        XCTAssertEqual(navigation.consumePendingSeek(), 0)
        XCTAssertNil(navigation.consumePendingSeek())
    }

    func testSplitSourceMapUsesEvidenceTimestampAndRetainsReverseEvidence() {
        let sourceID = id(1)
        let firstPartID = id(11)
        let secondPartID = id(12)
        let content = MeetingTranscriptContent(
            baseTranscriptRevision: 4,
            rows: [
                row(id: firstPartID, sourceIDs: [sourceID], start: 3, end: 5),
                row(id: secondPartID, sourceIDs: [sourceID], start: 5, end: 8),
            ],
            chapters: [])
        var navigation = MeetingTranscriptNavigationState()

        navigation.reveal(sourceSegmentID: sourceID, at: 7, in: content)

        XCTAssertEqual(
            content.rowID(containingSourceSegmentID: sourceID),
            firstPartID,
            "timestamp-free callers retain deterministic first-row behavior")
        XCTAssertEqual(
            content.rowID(containingSourceSegmentID: sourceID, at: 7),
            secondPartID)
        XCTAssertEqual(content.sourceSegmentIDs(forRowID: secondPartID), [sourceID])
        XCTAssertEqual(navigation.focusedRowID, secondPartID)
        XCTAssertEqual(navigation.pendingSeek, 7)
    }

    func testComposedSplitSeeksTheOriginalAudioTimeline() throws {
        let sourceID = id(21)
        let source = segment(
            id: sourceID,
            start: 3,
            end: 8,
            text: "First part second part",
            language: "en")
        let firstPartID = id(22)
        let secondPartID = id(23)
        let correction = TranscriptCorrectionEvent(
            id: id(24),
            meetingID: meetingID,
            baseTranscriptRevision: 4,
            targetSegmentIDs: [sourceID],
            kind: .split([
                TranscriptCorrectionPart(
                    id: firstPartID,
                    text: "First part",
                    speakerID: nil,
                    language: "en",
                    startTime: 3,
                    endTime: 5),
                TranscriptCorrectionPart(
                    id: secondPartID,
                    text: "second part",
                    speakerID: nil,
                    language: "en",
                    startTime: 5,
                    endTime: 8),
            ]),
            sourceDeviceID: id(25),
            createdAt: Date(timeIntervalSince1970: 10))
        let composition = try ComposeTranscript().execute(
            baseTranscriptRevision: 4,
            baseMaterial: .raw,
            segments: [source],
            corrections: [correction])
        var navigation = MeetingTranscriptNavigationState()

        navigation.reveal(
            sourceSegmentID: sourceID,
            at: 7,
            in: composition.composed)

        XCTAssertEqual(composition.accepted.rows.map(\.id), [sourceID])
        XCTAssertEqual(composition.composed.rows.map(\.id), [firstPartID, secondPartID])
        XCTAssertEqual(
            composition.composed.rows.map(\.sourceSegmentIDs),
            [[sourceID], [sourceID]])
        XCTAssertEqual(composition.composed.rows.map(\.startTime), [3, 5])
        XCTAssertEqual(composition.composed.rows.map(\.endTime), [5, 8])
        XCTAssertEqual(navigation.focusedRowID, secondPartID)
        XCTAssertEqual(navigation.consumePendingSeek(), 7)
        XCTAssertEqual(source.startTime, 3)
        XCTAssertEqual(source.endTime, 8)
        XCTAssertEqual(source.text, "First part second part")
    }

    func testTimestampRouteFocusesTheVisibleRowBeforePlaybackExists() {
        let firstID = id(1)
        let secondID = id(2)
        let content = MeetingTranscriptContent(
            baseTranscriptRevision: 4,
            rows: [
                row(id: firstID, sourceIDs: [firstID], start: 3, end: 8),
                row(id: secondID, sourceIDs: [secondID], start: 12, end: 15),
            ],
            chapters: [])
        var navigation = MeetingTranscriptNavigationState()

        navigation.requestSeek(to: 12.5, in: content)

        XCTAssertEqual(content.rowID(at: -5), firstID)
        XCTAssertEqual(content.rowID(at: 10), firstID)
        XCTAssertEqual(content.rowID(at: 12.5), secondID)
        XCTAssertEqual(navigation.focusedRowID, secondID)
        XCTAssertEqual(navigation.pendingSeek, 12.5)
    }

    func testTwentyThousandRowsRemainAddressableAtThePlaybackFrontier() {
        let rows = (0..<20_000).map { index in
            let rowID = id(index + 1)
            let start = Double(index) * 2
            return row(
                id: rowID,
                sourceIDs: [rowID],
                start: start,
                end: start + 1)
        }
        let content = MeetingTranscriptContent(
            baseTranscriptRevision: 1,
            rows: rows,
            chapters: [])

        XCTAssertEqual(content.activeRowID(at: 39_998.5), id(20_000))
    }

    private func segment(
        id: UUID,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        language: String
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            meetingID: meetingID,
            channel: .system,
            text: text,
            language: language,
            startTime: start,
            endTime: end,
            confidence: 0.9,
            isFinal: true)
    }

    private func row(
        id: UUID,
        sourceIDs: [UUID],
        start: TimeInterval,
        end: TimeInterval
    ) -> MeetingTranscriptContent.Row {
        MeetingTranscriptContent.Row(
            id: id,
            sourceSegmentIDs: sourceIDs,
            speakerID: nil,
            channel: .system,
            text: "Row \(id.uuidString)",
            language: "en",
            startTime: start,
            endTime: end,
            confidence: 0.9,
            isFinal: true)
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
    }
}
