import Foundation
import XCTest

@testable import PortavozCore

final class TranscriptCorrectionReplicaMergeTests: XCTestCase {
    private let meetingID = MeetingID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000000701")!)
    private let segmentID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000702")!
    private let secondSegmentID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000712")!
    private let deviceA = UUID(
        uuidString: "00000000-0000-0000-0000-000000000703")!
    private let deviceB = UUID(
        uuidString: "00000000-0000-0000-0000-000000000704")!
    private let deviceC = UUID(
        uuidString: "00000000-0000-0000-0000-000000000713")!

    func testDisjointTextAndSpeakerLanesConvergeInCanonicalOrder() throws {
        let text = event(
            id: "00000000-0000-0000-0000-000000000705",
            kind: .replaceText(text: "Corrected", language: "en"),
            sourceDeviceID: deviceA,
            createdAt: Date(timeIntervalSince1970: 20))
        let speaker = event(
            id: "00000000-0000-0000-0000-000000000706",
            kind: .changeSpeaker(SpeakerID()),
            sourceDeviceID: deviceB,
            createdAt: Date(timeIntervalSince1970: 10))

        let forward = try TranscriptCorrectionReplicaMerge.merge(
            local: [text],
            remote: [speaker],
            meetingID: meetingID)
        let reverse = try TranscriptCorrectionReplicaMerge.merge(
            local: [speaker],
            remote: [text],
            meetingID: meetingID)

        XCTAssertEqual(forward, [speaker, text])
        XCTAssertEqual(reverse, forward)
    }

    func testThreeDeviceCompatibleReplicasConvergeAcrossMergePermutations() throws {
        let text = event(
            id: "00000000-0000-0000-0000-000000000714",
            kind: .replaceText(text: "Corrected", language: "en"),
            sourceDeviceID: deviceA,
            createdAt: Date(timeIntervalSince1970: 30))
        let speaker = event(
            id: "00000000-0000-0000-0000-000000000715",
            kind: .changeSpeaker(SpeakerID()),
            sourceDeviceID: deviceB,
            createdAt: Date(timeIntervalSince1970: 10))
        let suppression = event(
            id: "00000000-0000-0000-0000-000000000716",
            targetSegmentID: secondSegmentID,
            kind: .suppress,
            sourceDeviceID: deviceC,
            createdAt: Date(timeIntervalSince1970: 20))

        let textSpeakerThenSuppression = try merge(
            merge([text], [speaker]),
            [suppression])
        let speakerSuppressionThenText = try merge(
            merge([speaker], [suppression]),
            [text])
        let suppressionTextThenSpeaker = try merge(
            merge([suppression], [text]),
            [speaker])

        XCTAssertEqual(textSpeakerThenSuppression, [speaker, suppression, text])
        XCTAssertEqual(speakerSuppressionThenText, textSpeakerThenSuppression)
        XCTAssertEqual(suppressionTextThenSpeaker, textSpeakerThenSuppression)
    }

    func testCompetingTextLanesFailClosed() {
        let local = event(
            id: "00000000-0000-0000-0000-000000000707",
            kind: .replaceText(text: "Local", language: "en"),
            sourceDeviceID: deviceA,
            createdAt: Date(timeIntervalSince1970: 10))
        let remote = event(
            id: "00000000-0000-0000-0000-000000000708",
            kind: .replaceText(text: "Remote", language: "en"),
            sourceDeviceID: deviceB,
            createdAt: Date(timeIntervalSince1970: 11))

        XCTAssertThrowsError(try TranscriptCorrectionReplicaMerge.merge(
            local: [local],
            remote: [remote],
            meetingID: meetingID)) { error in
                guard case TranscriptCorrectionValidationError.overlappingTargets = error else {
                    return XCTFail("expected lane conflict, got \(error)")
                }
            }
    }

    func testMatchingEventTombstoneWinsRegardlessOfMergeDirection() throws {
        let live = event(
            id: "00000000-0000-0000-0000-000000000709",
            kind: .replaceText(text: "Corrected", language: "en"),
            sourceDeviceID: deviceA,
            createdAt: Date(timeIntervalSince1970: 10))
        let deletedAt = Date(timeIntervalSince1970: 20)
        let tombstone = event(
            id: "00000000-0000-0000-0000-000000000709",
            kind: .replaceText(text: "Corrected", language: "en"),
            sourceDeviceID: deviceA,
            createdAt: live.createdAt,
            updatedAt: deletedAt,
            deletedAt: deletedAt)

        XCTAssertEqual(try merge([live], [tombstone]), [tombstone])
        XCTAssertEqual(try merge([tombstone], [live]), [tombstone])
    }

    func testMatchingIdentityCannotRewriteImmutableMaterial() {
        let local = event(
            id: "00000000-0000-0000-0000-000000000710",
            kind: .replaceText(text: "Local", language: "en"),
            sourceDeviceID: deviceA,
            createdAt: Date(timeIntervalSince1970: 10))
        let remote = event(
            id: "00000000-0000-0000-0000-000000000710",
            kind: .replaceText(text: "Remote", language: "en"),
            sourceDeviceID: deviceA,
            createdAt: local.createdAt)

        XCTAssertThrowsError(try merge([local], [remote])) { error in
            XCTAssertEqual(
                error as? TranscriptCorrectionReplicaMergeError,
                .immutableRewrite(local.id))
        }
    }

    func testDivergentTombstoneTimesFailClosed() {
        let firstTime = Date(timeIntervalSince1970: 20)
        let secondTime = Date(timeIntervalSince1970: 21)
        let first = event(
            id: "00000000-0000-0000-0000-000000000711",
            kind: .replaceText(text: "Corrected", language: "en"),
            sourceDeviceID: deviceA,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: firstTime,
            deletedAt: firstTime)
        let second = event(
            id: "00000000-0000-0000-0000-000000000711",
            kind: .replaceText(text: "Corrected", language: "en"),
            sourceDeviceID: deviceA,
            createdAt: first.createdAt,
            updatedAt: secondTime,
            deletedAt: secondTime)

        XCTAssertThrowsError(try merge([first], [second])) { error in
            XCTAssertEqual(
                error as? TranscriptCorrectionReplicaMergeError,
                .divergentTombstone(first.id))
        }
    }

    private func merge(
        _ local: [TranscriptCorrectionEvent],
        _ remote: [TranscriptCorrectionEvent]
    ) throws -> [TranscriptCorrectionEvent] {
        try TranscriptCorrectionReplicaMerge.merge(
            local: local,
            remote: remote,
            meetingID: meetingID)
    }

    private func event(
        id: String,
        targetSegmentID: UUID? = nil,
        kind: TranscriptCorrectionKind,
        sourceDeviceID: UUID,
        createdAt: Date,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) -> TranscriptCorrectionEvent {
        TranscriptCorrectionEvent(
            id: UUID(uuidString: id)!,
            meetingID: meetingID,
            baseTranscriptRevision: 0,
            targetSegmentIDs: [targetSegmentID ?? segmentID],
            kind: kind,
            sourceDeviceID: sourceDeviceID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt)
    }
}
