import Foundation
import PortavozCore
import XCTest

final class TranscriptStructuralSearchProjectionTests: XCTestCase {
    func testSplitProjectsStablePartIdentitiesAndAcceptedProvenance() {
        let fixture = makeFixture()
        let parts = [
            TranscriptCorrectionPart(
                id: id(101), text: "alpha launch", speakerID: fixture.speakerID,
                language: "en", startTime: 0, endTime: 1),
            TranscriptCorrectionPart(
                id: id(102), text: "beta review", speakerID: fixture.speakerID,
                language: "en", startTime: 1, endTime: 2)
        ]

        let rows = TranscriptStructuralSearchProjection.activeRows(
            history: [event(
                201,
                fixture: fixture,
                targets: [fixture.segments[0].id],
                kind: .split(parts))],
            meetingID: fixture.meetingID,
            baseTranscriptRevision: 3,
            segments: fixture.segments)

        XCTAssertEqual(rows.map(\.resultID), parts.map(\.id))
        XCTAssertEqual(rows.map(\.sourceSegmentIDs), [
            [fixture.segments[0].id], [fixture.segments[0].id]
        ])
        XCTAssertEqual(rows.map(\.kind), [.split, .split])
        XCTAssertEqual(rows.map(\.text), ["alpha launch", "beta review"])
    }

    func testMergeProjectsCorrectionIdentityAndOrderedSources() {
        let fixture = makeFixture()
        let correction = event(
            202,
            fixture: fixture,
            targets: fixture.segments.map(\.id),
            kind: .merge(replacementText: nil, language: nil))

        let rows = TranscriptStructuralSearchProjection.activeRows(
            history: [correction],
            meetingID: fixture.meetingID,
            baseTranscriptRevision: 3,
            segments: fixture.segments)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].resultID, correction.id)
        XCTAssertEqual(rows[0].sourceSegmentIDs, fixture.segments.map(\.id))
        XCTAssertEqual(rows[0].text, "alpha launch beta review")
        XCTAssertEqual(rows[0].startTime, 0)
        XCTAssertEqual(rows[0].endTime, 4)
    }

    func testSuppressAndRestoreProjectNoStructuralContent() {
        let fixture = makeFixture()
        let suppression = event(
            203,
            fixture: fixture,
            targets: [fixture.segments[0].id],
            kind: .suppress)
        let restore = event(
            204,
            fixture: fixture,
            targets: suppression.targetSegmentIDs,
            kind: .restore,
            supersedes: suppression.id)

        XCTAssertTrue(TranscriptStructuralSearchProjection.activeRows(
            history: [suppression],
            meetingID: fixture.meetingID,
            baseTranscriptRevision: 3,
            segments: fixture.segments).isEmpty)
        XCTAssertTrue(TranscriptStructuralSearchProjection.activeRows(
            history: [suppression, restore],
            meetingID: fixture.meetingID,
            baseTranscriptRevision: 3,
            segments: fixture.segments).isEmpty)
    }

    func testMalformedStructuralMaterialFailsClosedForWholeMeeting() {
        let fixture = makeFixture()
        let invalidParts = [
            TranscriptCorrectionPart(
                id: id(105), text: "alpha", speakerID: fixture.speakerID,
                language: "en", startTime: 0, endTime: 0.5),
            TranscriptCorrectionPart(
                id: id(106), text: "gap", speakerID: fixture.speakerID,
                language: "en", startTime: 1, endTime: 2)
        ]

        XCTAssertTrue(TranscriptStructuralSearchProjection.activeRows(
            history: [event(
                205,
                fixture: fixture,
                targets: [fixture.segments[0].id],
                kind: .split(invalidParts))],
            meetingID: fixture.meetingID,
            baseTranscriptRevision: 3,
            segments: fixture.segments).isEmpty)
    }

    private struct Fixture {
        let meetingID: MeetingID
        let speakerID: SpeakerID
        let segments: [TranscriptSegment]
    }

    private func makeFixture() -> Fixture {
        let meetingID = MeetingID(rawValue: id(1))
        let speakerID = SpeakerID(rawValue: id(2))
        return Fixture(
            meetingID: meetingID,
            speakerID: speakerID,
            segments: [
                TranscriptSegment(
                    id: id(11), meetingID: meetingID, speakerID: speakerID,
                    channel: .system, text: "alpha launch", language: "en",
                    startTime: 0, endTime: 2, isFinal: true),
                TranscriptSegment(
                    id: id(12), meetingID: meetingID, speakerID: speakerID,
                    channel: .system, text: "beta review", language: "en",
                    startTime: 2, endTime: 4, isFinal: true)
            ])
    }

    private func event(
        _ value: Int,
        fixture: Fixture,
        targets: [UUID],
        kind: TranscriptCorrectionKind,
        supersedes: UUID? = nil
    ) -> TranscriptCorrectionEvent {
        TranscriptCorrectionEvent(
            id: id(value),
            meetingID: fixture.meetingID,
            baseTranscriptRevision: 3,
            targetSegmentIDs: targets,
            kind: kind,
            sourceDeviceID: id(9),
            createdAt: Date(timeIntervalSince1970: TimeInterval(value)),
            supersedesCorrectionID: supersedes)
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
    }
}
