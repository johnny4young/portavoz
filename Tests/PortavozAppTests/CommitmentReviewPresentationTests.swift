import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

@testable import portavoz_app

@MainActor
final class CommitmentReviewPresentationTests: XCTestCase {
    private let meetingID = MeetingID()
    private let marta = SpeakerID()
    private let me = SpeakerID()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func segment(at time: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meetingID, speakerID: marta, channel: .system,
            text: "test both PRs together", startTime: time, endTime: time + 4, isFinal: true)
    }

    private func item(
        _ segments: [TranscriptSegment],
        count: Int? = nil,
        status: TranscriptEvidenceStatus = .current,
        owner: String? = "Ilarion"
    ) -> CommitmentReviewQueueItem {
        CommitmentReviewQueueItem(
            meetingID: meetingID,
            meetingTitle: "Planning Q4",
            meetingStartedAt: start,
            meetingEndedAt: start.addingTimeInterval(200),
            actionItem: ActionItem(text: "Test the lot-entry PR and the alerts PR together."),
            evidence: TranscriptEvidenceResolution(status: status, segments: segments),
            evidenceCount: count ?? segments.count,
            suggestedOwner: owner.map { CommitmentReviewQueueOwner(personID: PersonID(), displayName: $0) },
            reason: .newAfterMeeting)
    }

    private func voices(for item: CommitmentReviewQueueItem, speaker: SpeakerID) -> CommitmentReviewVoices {
        let columns = MeetingVoiceColumns(
            duration: 200,
            columns: [0, 0, 1, 1],
            voices: [
                .init(speakerID: marta, isMe: false, label: "S1", displayName: "Marta",
                      talkSeconds: 100, firstHeard: 0),
                .init(speakerID: me, isMe: true, label: "Me", displayName: nil,
                      talkSeconds: 100, firstHeard: 100)
            ])
        let source = VoiceStripSource(columns: columns)
        return CommitmentReviewVoices(
            items: [item.id: .init(voice: source.voices.first { $0.speakerID == speaker }, moments: [0.25, 0.5])],
            strips: [.init(meetingID: meetingID, source: source)])
    }

    func testRowSaysWhoSaidItWithTheSuggestedOwnerMeetingAndMoments() async throws {
        let candidate = item([segment(at: 50), segment(at: 100)])
        let row = try XCTUnwrap(
            CommitmentReviewPresentation.rows([candidate], voices: voices(for: candidate, speaker: marta)).first)

        XCTAssertEqual(row.speaker?.name, "Marta")
        XCTAssertEqual(row.speaker?.isMe, false)
        XCTAssertNotEqual(row.speaker?.tint, .grey, "a named voice keeps its strip colour")
        XCTAssertEqual(row.speaker.map { String($0.saidIt.characters) }, "Marta said it")
        XCTAssertEqual(row.ownerChip, "Owner: Ilarion?")
        XCTAssertEqual(row.meeting(now: start), "Planning Q4 · today")
        XCTAssertNotNil(row.strip)
        XCTAssertEqual(row.moments, [0.25, 0.5])
        XCTAssertEqual(row.firstMoment, 50)
        XCTAssertTrue(row.canConfirm)
    }

    func testYouSaidItTakesYourTint() async throws {
        let candidate = item([segment(at: 120)], owner: nil)
        let row = try XCTUnwrap(
            CommitmentReviewPresentation.rows([candidate], voices: voices(for: candidate, speaker: me)).first)

        XCTAssertEqual(row.speaker?.isMe, true)
        XCTAssertEqual(row.speaker?.tint, .you)
        XCTAssertEqual(row.speaker.map { String($0.saidIt.characters) }, "You said it")
        XCTAssertNil(row.ownerChip, "no owner chip without a suggestion")
    }

    func testBeforeVoicesLandTheRowStillConfirmsButNamesNobody() async throws {
        let row = try XCTUnwrap(CommitmentReviewPresentation.rows([item([segment(at: 3)])], voices: .empty).first)

        XCTAssertNil(row.speaker)
        XCTAssertNil(row.strip)
        XCTAssertEqual(row.moments, [])
        XCTAssertTrue(row.canConfirm)
    }

    func testStaleOrEmptyEvidenceCannotConfirmOrSeek() async throws {
        let rows = CommitmentReviewPresentation.rows(
            [item([segment(at: 3)], status: .stale), item([])], voices: .empty)

        XCTAssertEqual(rows.map(\.canConfirm), [false, false])
        XCTAssertEqual(rows.map(\.firstMoment), [nil, nil])
    }

    func testTimesShowThreeMomentsAndCountTheRest() async throws {
        let segments = (0..<5).map { segment(at: Double($0) * 10) }
        let row = try XCTUnwrap(CommitmentReviewPresentation.rows([item(segments, count: 7)], voices: .empty).first)

        XCTAssertEqual(row.shownSegments.map(\.startTime), [0, 10, 20])
        XCTAssertEqual(row.hiddenMomentCount, 4, "the preview's unseen moments and the truncated ones")
    }
}
