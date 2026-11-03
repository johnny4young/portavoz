import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class TranscriptCorrectionRevisionTests: XCTestCase {
    func testRevisionIsOrderIndependentAndRestoreReturnsToAcceptedReading() throws {
        let meetingID = MeetingID(rawValue: id(1))
        let sourceID = id(2)
        let first = event(
            10,
            meetingID: meetingID,
            sourceID: sourceID,
            kind: .replaceText(text: "Corrected", language: "en"))
        let second = event(
            11,
            meetingID: meetingID,
            sourceID: sourceID,
            kind: .changeSpeaker(SpeakerID(rawValue: id(3))))

        let forward = try TranscriptCorrectionRevision.current(
            meetingID: meetingID,
            baseTranscriptRevision: 4,
            history: [first, second])
        let reverse = try TranscriptCorrectionRevision.current(
            meetingID: meetingID,
            baseTranscriptRevision: 4,
            history: [second, first])
        XCTAssertEqual(forward, reverse)
        XCTAssertFalse(forward.isAccepted)

        let restoreText = event(
            12,
            meetingID: meetingID,
            sourceID: sourceID,
            kind: .restore,
            supersedes: first.id)
        let restoreSpeaker = event(
            13,
            meetingID: meetingID,
            sourceID: sourceID,
            kind: .restore,
            supersedes: second.id)
        XCTAssertEqual(
            try TranscriptCorrectionRevision.current(
                meetingID: meetingID,
                baseTranscriptRevision: 4,
                history: [first, second, restoreText, restoreSpeaker]),
            .accepted)
    }

    func testArtifactSourcesKeepLegacyCompatibilityOnlyForAcceptedReading() throws {
        let revision = try XCTUnwrap(TranscriptCorrectionRevision(
            rawValue: String(repeating: "a", count: 64)))
        let current = TranscriptCorrectionArtifactSource(
            generationConfigJSON: #"{"sourceCorrectionRevision":"\#(revision.rawValue)"}"#)
        XCTAssertTrue(current.matches(revision))
        XCTAssertFalse(current.matches(.accepted))

        let legacy = TranscriptCorrectionArtifactSource(generationConfigJSON: "{}")
        XCTAssertTrue(legacy.matches(.accepted))
        XCTAssertFalse(legacy.matches(revision))

        let malformed = TranscriptCorrectionArtifactSource(
            generationConfigJSON: "{\"sourceCorrectionRevision\":\"invalid\"}")
        XCTAssertEqual(malformed, .invalid)
        XCTAssertFalse(malformed.matches(.accepted))

        XCTAssertTrue(TranscriptRevisionArtifactSource(
            generationConfigJSON: "{\"sourceTranscriptRevision\":4}")
            .matches(4))
        XCTAssertEqual(
            TranscriptRevisionArtifactSource(
                generationConfigJSON: "{\"sourceTranscriptRevision\":-1}"),
            .invalid)
    }

    func testReadModelMarksLegacyArtifactsStaleAfterACorrection() throws {
        let meeting = Meeting(
            title: "Correction freshness",
            startedAt: date(0),
            transcriptRevision: 4)
        let source = TranscriptSegment(
            id: id(2),
            meetingID: meeting.id,
            channel: .system,
            text: "Original",
            startTime: 0,
            endTime: 1,
            isFinal: true)
        let correction = event(
            10,
            meetingID: meeting.id,
            sourceID: source.id,
            kind: .replaceText(text: "Corrected", language: "en"))
        let revision = try TranscriptCorrectionRevision.current(
            meetingID: meeting.id,
            baseTranscriptRevision: 4,
            history: [correction])
        let card = CompanionCard(
            id: id(20),
            question: "What changed?",
            answer: "The transcript.",
            kind: .context,
            source: "meeting",
            askedAt: 1)
        let summary = MeetingReviewSummary(
            draft: SummaryDraft(
                meetingID: meeting.id,
                recipeID: Recipe.general.id,
                language: "en",
                markdown: "Corrected summary",
                actionItems: []),
            version: 1)
        let review = MeetingReviewReadModel(
            core: MeetingReviewCore(
                meeting: meeting,
                speakers: [],
                segments: [source],
                corrections: [correction],
                correctionRevision: revision),
            summary: summary,
            companionCards: [card],
            privacyReceipt: nil,
            processingJobs: [])

        XCTAssertEqual(review.summaryFreshness, .stale)
        XCTAssertEqual(review.companionFreshness(card), .stale)
    }
}

private extension TranscriptCorrectionRevisionTests {
    func event(
        _ value: Int,
        meetingID: MeetingID,
        sourceID: UUID,
        kind: TranscriptCorrectionKind,
        supersedes: UUID? = nil
    ) -> TranscriptCorrectionEvent {
        TranscriptCorrectionEvent(
            id: id(value),
            meetingID: meetingID,
            baseTranscriptRevision: 4,
            targetSegmentIDs: [sourceID],
            kind: kind,
            sourceDeviceID: id(999),
            createdAt: date(TimeInterval(value)),
            supersedesCorrectionID: supersedes)
    }

    func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + offset)
    }

    func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
    }
}
