import Foundation

/// The searchable face of one active `replaceText` correction.
///
/// Citation identity stays the accepted `segmentID`: text replacement is the
/// only correction kind that is 1:1 with a segment, so it is the only kind
/// that can enter the search index without breaking every consumer that
/// deduplicates, links, or navigates by segment identity. Split, merge, and
/// suppress change row cardinality and stay out of search entirely.
public struct SegmentCorrectedText: Equatable, Sendable {
    public let segmentID: UUID
    public let correctionID: UUID
    public let text: String
    public let language: String?
    public let updatedAt: Date

    public init(
        segmentID: UUID,
        correctionID: UUID,
        text: String,
        language: String?,
        updatedAt: Date
    ) {
        self.segmentID = segmentID
        self.correctionID = correctionID
        self.text = text
        self.language = language
        self.updatedAt = updatedAt
    }
}

/// Resolves which corrected texts a meeting's search projection may carry.
public enum SegmentCorrectedTextProjection {
    /// Active text replacements for the current revision, resolved with the
    /// same rules as `TranscriptCorrectionPolicy.effectiveCorrections`.
    ///
    /// Fails closed: a malformed history — including active corrections that
    /// overlap one segment across lanes — projects nothing for the whole
    /// meeting. The per-segment conflict and structural filters below are
    /// defense in depth for histories `validateHistory` would not admit.
    public static func activeReplacements(
        history: [TranscriptCorrectionEvent],
        meetingID: MeetingID,
        baseTranscriptRevision: Int
    ) -> [SegmentCorrectedText] {
        guard let effective = try? TranscriptCorrectionPolicy.effectiveCorrections(
            in: history,
            meetingID: meetingID,
            baseTranscriptRevision: baseTranscriptRevision)
        else { return [] }

        var structuralTargets: Set<UUID> = []
        for event in effective {
            switch event.kind {
            case .split, .merge, .suppress:
                structuralTargets.formUnion(event.targetSegmentIDs)
            case .replaceText, .changeSpeaker, .restore:
                break
            }
        }

        var candidatesBySegment: [UUID: [SegmentCorrectedText]] = [:]
        for event in effective {
            guard case .replaceText(let text, let language) = event.kind,
                  event.targetSegmentIDs.count == 1,
                  let segmentID = event.targetSegmentIDs.first
            else { continue }
            candidatesBySegment[segmentID, default: []].append(
                SegmentCorrectedText(
                    segmentID: segmentID,
                    correctionID: event.id,
                    text: text,
                    language: language,
                    updatedAt: event.updatedAt))
        }

        return candidatesBySegment
            .filter { segmentID, candidates in
                candidates.count == 1 && !structuralTargets.contains(segmentID)
            }
            .flatMap(\.value)
            .sorted { $0.segmentID.uuidString < $1.segmentID.uuidString }
    }
}
