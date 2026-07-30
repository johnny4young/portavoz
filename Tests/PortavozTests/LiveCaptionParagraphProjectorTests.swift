import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

final class LiveCaptionParagraphProjectorTests: XCTestCase {
    private let meetingID = MeetingID()

    private func row(
        _ text: String,
        channel: AudioChannel,
        start: TimeInterval,
        end: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meetingID,
            channel: channel,
            text: text,
            startTime: start,
            endTime: end,
            isFinal: true)
    }

    func testConsecutiveMicrophoneRowsBecomeOneDisplayParagraph() {
        let first = row("I reviewed the plan.", channel: .microphone, start: 0, end: 1)
        let second = row("The release is tomorrow.", channel: .microphone, start: 1.3, end: 2)

        let result = LiveCaptionParagraphProjector.project(
            captions: [first, second],
            liveSpeakerLabels: [:],
            translations: [
                first.id: "Revisé el plan.",
                second.id: "El lanzamiento es mañana.",
            ])

        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].id, first.id)
        XCTAssertEqual(
            result.segments[0].text,
            "I reviewed the plan. The release is tomorrow.")
        XCTAssertEqual(
            result.translations[first.id],
            "Revisé el plan. El lanzamiento es mañana.")
    }

    func testConsecutiveRowsWithSameStableRemoteVoiceBecomeOneParagraph() {
        let first = row("The schema is ready.", channel: .system, start: 0, end: 1)
        let second = row("I will open the PR.", channel: .system, start: 1.2, end: 2)

        let result = LiveCaptionParagraphProjector.project(
            captions: [first, second],
            liveSpeakerLabels: [first.id: "S1", second.id: "S1"],
            translations: [:])

        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].text, "The schema is ready. I will open the PR.")
    }

    func testGenericThemRowsNeverMergeBeforeDiarizationKnowsTheVoice() {
        let first = row("Did that answer the question?", channel: .system, start: 0, end: 1)
        let second = row("Yes, thank you.", channel: .system, start: 1.1, end: 2)

        let result = LiveCaptionParagraphProjector.project(
            captions: [first, second],
            liveSpeakerLabels: [:],
            translations: [:])

        XCTAssertEqual(result.segments.map(\.id), [first.id, second.id])
    }

    func testDifferentStableVoicesNeverMerge() {
        let first = row("Speaker one.", channel: .system, start: 0, end: 1)
        let second = row("Speaker two.", channel: .system, start: 1.1, end: 2)

        let result = LiveCaptionParagraphProjector.project(
            captions: [first, second],
            liveSpeakerLabels: [first.id: "S1", second.id: "S2"],
            translations: [:])

        XCTAssertEqual(result.segments.map(\.id), [first.id, second.id])
    }

    func testLongPauseStartsANewParagraphForTheSameVoice() {
        let first = row("First topic.", channel: .microphone, start: 0, end: 1)
        let second = row("Later topic.", channel: .microphone, start: 7, end: 8)

        let result = LiveCaptionParagraphProjector.project(
            captions: [first, second],
            liveSpeakerLabels: [:],
            translations: [:])

        XCTAssertEqual(result.segments.map(\.id), [first.id, second.id])
    }

    func testProjectionOwnsBoundedRecentSourceWindow() {
        let rows = (0..<(LiveCaptionParagraphProjector.maximumSourceRows + 25)).map {
            row(
                "Remote turn \($0).",
                channel: .system,
                start: TimeInterval($0 * 5),
                end: TimeInterval($0 * 5 + 1))
        }
        let firstRetained = rows[rows.count - LiveCaptionParagraphProjector.maximumSourceRows]
        let result = LiveCaptionParagraphProjector.project(
            captions: rows,
            liveSpeakerLabels: [:],
            translations: [
                rows[0].id: "Dropped.",
                firstRetained.id: "Retained.",
            ])

        XCTAssertEqual(
            result.segments.map(\.id),
            Array(rows.suffix(LiveCaptionParagraphProjector.maximumSourceRows)).map(\.id))
        XCTAssertNil(result.translations[rows[0].id])
        XCTAssertEqual(result.translations[firstRetained.id], "Retained.")
    }
}
