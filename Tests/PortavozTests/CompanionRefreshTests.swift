import Foundation
import PortavozCore
import XCTest
@testable import portavoz_app

final class CompanionRefreshTests: XCTestCase {
    func testRecentPassagesUsesTheStrictBoundedPrefix() {
        let meetingID = MeetingID()
        let segments = (0..<20).map { index in
            TranscriptSegment(
                meetingID: meetingID,
                channel: index.isMultiple(of: 2) ? .microphone : .system,
                text: "row-\(index)",
                startTime: TimeInterval(index),
                endTime: TimeInterval(index + 1),
                isFinal: true)
        }

        let passages = CompanionTranscriptContext.recentPassages(
            before: 18,
            from: segments,
            meetingID: meetingID)

        XCTAssertEqual(passages.count, 14)
        XCTAssertEqual(passages.map(\.timestamp), (4..<18).map(TimeInterval.init))
        XCTAssertEqual(passages.first?.text, "Me: row-4")
        XCTAssertEqual(passages.last?.text, "Them: row-17")
        XCTAssertFalse(passages.contains { $0.timestamp == 18 })
    }

    func testRecentPassagesHandlesEmptyAndEqualTimestampBoundaries() {
        let meetingID = MeetingID()
        let segment = TranscriptSegment(
            meetingID: meetingID,
            channel: .system,
            text: "question",
            startTime: 5,
            endTime: 6,
            isFinal: true)

        XCTAssertTrue(CompanionTranscriptContext.recentPassages(
            before: 5,
            from: [segment],
            meetingID: meetingID).isEmpty)
        XCTAssertTrue(CompanionTranscriptContext.recentPassages(
            before: 5,
            from: [],
            meetingID: meetingID).isEmpty)
    }
}
