import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class MeetingTranscriptGenerationMaterialTests: XCTestCase {
    func testComposedMaterialFeedsGenerationAndProjectsEvidenceToAcceptedRows() throws {
        let meeting = Meeting(
            title: "Corrected generation",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            transcriptRevision: 4)
        let speaker = Speaker(meetingID: meeting.id, label: "S1")
        let first = segment(
            1,
            meeting: meeting,
            speaker: speaker,
            text: "First source",
            start: 0,
            end: 2)
        let second = segment(
            2,
            meeting: meeting,
            speaker: speaker,
            text: "Second source",
            start: 3,
            end: 5)
        let merge = TranscriptCorrectionEvent(
            id: id(101),
            meetingID: meeting.id,
            baseTranscriptRevision: meeting.transcriptRevision,
            targetSegmentIDs: [first.id, second.id],
            kind: .merge(replacementText: "Combined source", language: "en"),
            sourceDeviceID: id(900),
            createdAt: Date(timeIntervalSince1970: 101))
        let review = MeetingReviewReadModel(
            core: MeetingReviewCore(
                meeting: meeting,
                speakers: [speaker],
                segments: [first, second],
                corrections: [merge]),
            summary: nil,
            companionCards: [],
            privacyReceipt: nil,
            processingJobs: [])

        let material = review.transcriptGenerationMaterial()

        XCTAssertEqual(material.segments.map(\.id), [merge.id])
        XCTAssertEqual(material.segments.map(\.text), ["Combined source"])
        XCTAssertEqual(
            material.sourceSegmentIDsByGeneratedID[merge.id],
            [first.id, second.id])
        XCTAssertFalse(material.correctionRevision.isAccepted)

        let action = ActionItem(text: "Ship it")
        let projected = material.projectingEvidence(in: SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "## Summary",
            actionItems: [action],
            claims: [SummaryClaim(
                kind: .overview,
                sourceTranscriptRevision: 99,
                evidenceSegmentIDs: [merge.id, merge.id],
                unavailableEvidenceCount: 2)],
            decisionEvidence: [SummaryDecisionEvidence(
                sectionOrdinal: 0,
                bulletOrdinal: 0,
                sourceTranscriptRevision: 99,
                evidenceSegmentIDs: [merge.id])],
            actionItemEvidence: [SummaryActionItemEvidence(
                actionItemID: action.id,
                sourceTranscriptRevision: 99,
                evidenceSegmentIDs: [merge.id])]))

        XCTAssertEqual(projected.claims.first?.sourceTranscriptRevision, 4)
        XCTAssertEqual(projected.claims.first?.evidenceSegmentIDs, [first.id, second.id])
        XCTAssertEqual(projected.claims.first?.unavailableEvidenceCount, 2)
        XCTAssertEqual(
            projected.decisionEvidence.first?.evidenceSegmentIDs,
            [first.id, second.id])
        XCTAssertEqual(
            projected.actionItemEvidence.first?.evidenceSegmentIDs,
            [first.id, second.id])
    }

    private func segment(
        _ value: Int,
        meeting: Meeting,
        speaker: Speaker,
        text: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id(value),
            meetingID: meeting.id,
            speakerID: speaker.id,
            channel: .system,
            text: text,
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
