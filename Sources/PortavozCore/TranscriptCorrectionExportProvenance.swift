import Foundation

/// Portable audit metadata for an explicitly correction-aware document.
///
/// The exported text is a projection only. Accepted transcript rows and local
/// audio remain unchanged, while generated rows retain their immutable source
/// segment identities for readers that request provenance.
public struct TranscriptCorrectionExportProvenance: Sendable, Equatable {
    public let baseTranscriptRevision: Int
    public let correctionRevision: TranscriptCorrectionRevision
    public let activeCorrectionIDs: [UUID]
    public let sourceSegmentIDsByExportedSegmentID: [UUID: [UUID]]

    public init(
        baseTranscriptRevision: Int,
        correctionRevision: TranscriptCorrectionRevision,
        activeCorrectionIDs: [UUID],
        sourceSegmentIDsByExportedSegmentID: [UUID: [UUID]]
    ) {
        self.baseTranscriptRevision = baseTranscriptRevision
        self.correctionRevision = correctionRevision
        self.activeCorrectionIDs = activeCorrectionIDs.sorted {
            $0.uuidString < $1.uuidString
        }
        self.sourceSegmentIDsByExportedSegmentID =
            sourceSegmentIDsByExportedSegmentID
    }
}
