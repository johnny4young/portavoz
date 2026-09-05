import Foundation
import PortavozCore

/// Corrected transcript material admitted to an explicit generation request.
/// Generated rows remain ephemeral; their evidence is projected back to
/// immutable accepted segment identities before persistence.
public struct MeetingTranscriptGenerationMaterial: Sendable {
    public let segments: [TranscriptSegment]
    public let sourceSegmentIDsByGeneratedID: [UUID: [UUID]]
    public let baseTranscriptRevision: Int
    public let correctionRevision: TranscriptCorrectionRevision

    public init(
        segments: [TranscriptSegment],
        sourceSegmentIDsByGeneratedID: [UUID: [UUID]],
        baseTranscriptRevision: Int,
        correctionRevision: TranscriptCorrectionRevision
    ) {
        self.segments = segments
        self.sourceSegmentIDsByGeneratedID = sourceSegmentIDsByGeneratedID
        self.baseTranscriptRevision = baseTranscriptRevision
        self.correctionRevision = correctionRevision
    }

    public func projectingEvidence(in draft: SummaryDraft) -> SummaryDraft {
        SummaryDraft(
            meetingID: draft.meetingID,
            recipeID: draft.recipeID,
            language: draft.language,
            markdown: draft.markdown,
            actionItems: draft.actionItems,
            fingerprint: draft.fingerprint,
            claims: draft.claims.map { claim in
                SummaryClaim(
                    id: claim.id,
                    kind: claim.kind,
                    sourceTranscriptRevision: baseTranscriptRevision,
                    evidenceSegmentIDs: acceptedIDs(for: claim.evidenceSegmentIDs),
                    unavailableEvidenceCount: claim.unavailableEvidenceCount,
                    feedback: claim.feedback)
            },
            decisionEvidence: draft.decisionEvidence.map { evidence in
                SummaryDecisionEvidence(
                    id: evidence.id,
                    sectionOrdinal: evidence.sectionOrdinal,
                    bulletOrdinal: evidence.bulletOrdinal,
                    sourceTranscriptRevision: baseTranscriptRevision,
                    evidenceSegmentIDs: acceptedIDs(for: evidence.evidenceSegmentIDs),
                    unavailableEvidenceCount: evidence.unavailableEvidenceCount)
            },
            actionItemEvidence: draft.actionItemEvidence.map { evidence in
                SummaryActionItemEvidence(
                    id: evidence.id,
                    actionItemID: evidence.actionItemID,
                    sourceTranscriptRevision: baseTranscriptRevision,
                    evidenceSegmentIDs: acceptedIDs(for: evidence.evidenceSegmentIDs),
                    unavailableEvidenceCount: evidence.unavailableEvidenceCount)
            })
    }

    private func acceptedIDs(for generatedIDs: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return generatedIDs
            .flatMap { sourceSegmentIDsByGeneratedID[$0] ?? [$0] }
            .filter { seen.insert($0).inserted }
    }
}

public extension MeetingReviewReadModel {
    func transcriptGenerationMaterial() -> MeetingTranscriptGenerationMaterial {
        let content = transcriptContent()
        let generated = content.rows.map { row in
            TranscriptSegment(
                id: row.id,
                meetingID: meeting.id,
                speakerID: row.speakerID,
                channel: row.channel,
                text: row.text,
                language: row.language,
                startTime: row.startTime,
                endTime: row.endTime,
                confidence: row.confidence,
                isFinal: row.isFinal)
        }
        return MeetingTranscriptGenerationMaterial(
            segments: generated,
            sourceSegmentIDsByGeneratedID: Dictionary(
                uniqueKeysWithValues: content.rows.map { ($0.id, $0.sourceSegmentIDs) }),
            baseTranscriptRevision: meeting.transcriptRevision,
            correctionRevision: correctionRevision)
    }
}
