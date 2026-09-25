import Foundation
import PortavozCore
import TranscriptionKit
import XCTest

@testable import portavoz_app

final class DictationTranscriptProjectionTests: XCTestCase {
    private let meetingID = MeetingID()

    func testEveryAdmittedShapeMatchesFullProjectionIncludingReopenedRows() {
        var projection = DictationTranscriptProjection()
        let coalescer = CaptionCoalescer()
        var reference: [TranscriptSegment] = []
        var inputs: [TranscriptSegment] = []
        for index in 0..<40 {
            let time = Double(index) * 40
            inputs += [
                segment("Remote context \(index)", .system, time),
                segment("Conserva estas notas \(index)", .microphone, time + 1),
                segment("Conserva estas notas \(index)", .system, time + 1.1),
                segment("", .microphone, time + 1.2),
                segment("Don’t remove Café", .microphone, time + 8),
                segment("Café C++", .microphone, time + 8.2),
                segment("?!", .microphone, time + 8.4),
                segment("DDDDDD", .microphone, time + 8.6),
                segment("....", .microphone, time + 8.8),
                segment("Earlier callback", .microphone, time - 1),
                segment("Room turn", .room, time + 20),
                segment("Room turn", .microphone, time + 20.1),
            ]
        }
        for (index, input) in inputs.enumerated() {
            let previous = reference
            let invalidated = coalescer.apply(input, to: &reference)
            _ = projection.apply(input)
            XCTAssertEqual(projection.confirmedText, reference.dropLast().map(\.text).joined(separator: " "),
                           "Closed projection at input \(index)")
            XCTAssertEqual(projection.partialText, reference.last?.text ?? "", "Tail at input \(index)")
            XCTAssertEqual(projection.finalText, reference.map(\.text).joined(separator: " "),
                           "Final projection at input \(index)")
            if let invalidated {
                XCTAssertGreaterThanOrEqual(invalidated, 0)
                XCTAssertLessThan(invalidated, reference.count)
                XCTAssertEqual(previous.prefix(invalidated).map(\.id), reference.prefix(invalidated).map(\.id))
                XCTAssertEqual(previous.prefix(invalidated).map(\.text), reference.prefix(invalidated).map(\.text))
            } else {
                XCTAssertEqual(previous.map(\.id), reference.map(\.id))
                XCTAssertEqual(previous.map(\.text), reference.map(\.text))
            }
        }
    }

    func testPartialNoiseAndSameCountReplacementDoNotRepublishClosedText() {
        var projection = DictationTranscriptProjection()
        XCTAssertFalse(projection.apply(segment("Original words", .microphone, 0)))
        XCTAssertFalse(projection.apply(segment("continue", .microphone, 0.5)))
        XCTAssertFalse(projection.apply(segment(".", .microphone, 0.6)))
        XCTAssertTrue(projection.apply(segment("Copied remote phrase", .microphone, 8)))
        XCTAssertFalse(projection.apply(segment("Copied remote phrase", .system, 8.1)))
        XCTAssertFalse(projection.apply(segment("DDDDDD", .microphone, 8.2)))
        XCTAssertFalse(projection.apply(segment("   ", .microphone, 8.3)))
        XCTAssertEqual(projection.confirmedText, "Original words continue.")
        XCTAssertEqual(projection.partialText, "Copied remote phrase")
    }

    func testCoalescerReportsEarlierInvalidationWhenAnEchoReopensRemoteText() {
        let coalescer = CaptionCoalescer()
        var rows: [TranscriptSegment] = []
        XCTAssertEqual(coalescer.apply(segment("Older immutable turn", .room, 0), to: &rows), 0)
        XCTAssertEqual(coalescer.apply(segment("Previous remote statement", .system, 8), to: &rows), 1)
        XCTAssertEqual(coalescer.apply(segment("Please record tomorrow’s deadline", .microphone, 9), to: &rows), 2)
        let original = rows[0]
        XCTAssertEqual(coalescer.apply(segment("Please record tomorrow’s deadline", .system, 9.1), to: &rows), 1)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].id, original.id)
        XCTAssertEqual(rows[0].text, original.text)
        XCTAssertEqual(rows[1].text, "Previous remote statement Please record tomorrow’s deadline")
    }

    private func segment(_ text: String, _ channel: AudioChannel, _ time: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(meetingID: meetingID, channel: channel, text: text, startTime: time, endTime: time + 0.5)
    }
}
