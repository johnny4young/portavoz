import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

final class MeetingDetailSummaryPlaceholderTests: XCTestCase {
    func testOnlyTheNewestCancelledSummaryExplainsTheMissingPiece() {
        let meeting = MeetingID()
        func job(_ kind: ProcessingJobKind, _ state: ProcessingJobState, at seconds: TimeInterval) -> ProcessingJob {
            ProcessingJob(
                meetingID: meeting, kind: kind, inputFingerprint: "fixture", state: state,
                updatedAt: Date(timeIntervalSince1970: seconds))
        }
        let older = job(.summary, .cancelled, at: 100)
        let newest = job(.summary, .cancelled, at: 200)
        let unrelated = [job(.summary, .succeeded, at: 300), job(.transcription, .cancelled, at: 400)]

        let chosen = MeetingDetailSummaryPlaceholder.latestCancelledSummary(in: [older, newest] + unrelated)

        XCTAssertEqual(chosen?.id, newest.id)
        XCTAssertNil(MeetingDetailSummaryPlaceholder.latestCancelledSummary(in: unrelated))
    }
}
