import Foundation

/// The stable identity and accepted provenance of one searchable structural
/// transcript row.
///
/// Split parts keep their authored part identity; a merge keeps the correction
/// identity that already names its composed row. Suppression deliberately
/// produces no row. Consumers can therefore deduplicate and navigate by
/// `resultID` without pretending that a cardinality-changing edit is one
/// immutable accepted segment.
public struct TranscriptStructuralSearchRow: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case split
        case merge
    }

    public let resultID: UUID
    public let correctionID: UUID
    public let sourceSegmentIDs: [UUID]
    public let kind: Kind
    public let text: String
    public let language: String?
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let updatedAt: Date

    public init(
        resultID: UUID,
        correctionID: UUID,
        sourceSegmentIDs: [UUID],
        kind: Kind,
        text: String,
        language: String?,
        startTime: TimeInterval,
        endTime: TimeInterval,
        updatedAt: Date
    ) {
        self.resultID = resultID
        self.correctionID = correctionID
        self.sourceSegmentIDs = sourceSegmentIDs
        self.kind = kind
        self.text = text
        self.language = language
        self.startTime = startTime
        self.endTime = endTime
        self.updatedAt = updatedAt
    }
}

/// Pure, fail-closed structural search projection over accepted transcript
/// material and immutable correction history.
public enum TranscriptStructuralSearchProjection {
    public static func activeRows(
        history: [TranscriptCorrectionEvent],
        meetingID: MeetingID,
        baseTranscriptRevision: Int,
        segments: [TranscriptSegment]
    ) -> [TranscriptStructuralSearchRow] {
        guard baseTranscriptRevision >= 0,
              let effective = try? TranscriptCorrectionPolicy.effectiveCorrections(
                  in: history,
                  meetingID: meetingID,
                  baseTranscriptRevision: baseTranscriptRevision),
              let orderedSegments = validatedSegments(
                  segments,
                  meetingID: meetingID)
        else { return [] }

        let segmentByID = Dictionary(
            uniqueKeysWithValues: orderedSegments.map { ($0.id, $0) })
        let indexByID = Dictionary(
            uniqueKeysWithValues: orderedSegments.enumerated().map {
                ($0.element.id, $0.offset)
            })
        let acceptedIDs = Set(segmentByID.keys)
        var generatedIDs = Set<UUID>()
        var rows: [TranscriptStructuralSearchRow] = []

        for correction in effective {
            guard let projected = projectedRows(
                for: correction,
                segmentByID: segmentByID,
                indexByID: indexByID)
            else { return [] }

            for row in projected {
                guard !acceptedIDs.contains(row.resultID),
                      generatedIDs.insert(row.resultID).inserted
                else { return [] }
                rows.append(row)
            }
        }
        return rows.sorted {
            ($0.startTime, $0.endTime, $0.resultID.uuidString)
                < ($1.startTime, $1.endTime, $1.resultID.uuidString)
        }
    }
}

private extension TranscriptStructuralSearchProjection {
    static func projectedRows(
        for correction: TranscriptCorrectionEvent,
        segmentByID: [UUID: TranscriptSegment],
        indexByID: [UUID: Int]
    ) -> [TranscriptStructuralSearchRow]? {
        switch correction.kind {
        case .split(let parts):
            guard correction.targetSegmentIDs.count == 1,
                  let sourceID = correction.targetSegmentIDs.first,
                  let source = segmentByID[sourceID],
                  splitIsValid(parts, inside: source)
            else { return nil }
            return parts.map { part in
                TranscriptStructuralSearchRow(
                    resultID: part.id,
                    correctionID: correction.id,
                    sourceSegmentIDs: [source.id],
                    kind: .split,
                    text: part.text,
                    language: part.language,
                    startTime: part.startTime,
                    endTime: part.endTime,
                    updatedAt: correction.updatedAt)
            }
        case .merge(let replacementText, let replacementLanguage):
            guard let targets = mergedTargets(
                correction.targetSegmentIDs,
                segmentByID: segmentByID,
                indexByID: indexByID)
            else { return nil }
            let candidateLanguage = targets[0].language
            let commonLanguage = targets.allSatisfy {
                $0.language == candidateLanguage
            } ? candidateLanguage : nil
            return [TranscriptStructuralSearchRow(
                resultID: correction.id,
                correctionID: correction.id,
                sourceSegmentIDs: targets.map(\.id),
                kind: .merge,
                text: replacementText ?? targets.map(\.text).joined(separator: " "),
                language: replacementLanguage ?? commonLanguage,
                startTime: targets[0].startTime,
                endTime: targets[targets.count - 1].endTime,
                updatedAt: correction.updatedAt)]
        case .replaceText, .changeSpeaker, .suppress, .restore:
            return []
        }
    }

    static func validatedSegments(
        _ segments: [TranscriptSegment],
        meetingID: MeetingID
    ) -> [TranscriptSegment]? {
        guard Set(segments.map(\.id)).count == segments.count,
              segments.allSatisfy({ segment in
                  segment.meetingID == meetingID
                      && segment.isFinal
                      && segment.startTime.isFinite
                      && segment.endTime.isFinite
                      && segment.startTime >= 0
                      && segment.endTime >= segment.startTime
              })
        else { return nil }
        return segments.sorted {
            ($0.startTime, $0.endTime, $0.id.uuidString)
                < ($1.startTime, $1.endTime, $1.id.uuidString)
        }
    }

    static func splitIsValid(
        _ parts: [TranscriptCorrectionPart],
        inside source: TranscriptSegment
    ) -> Bool {
        guard parts.count >= 2,
              Set(parts.map(\.id)).count == parts.count
        else { return false }
        var priorEnd = source.startTime
        for part in parts {
            guard TranscriptContentPolicy.hasLexicalContent(part.text),
                  part.startTime.isFinite,
                  part.endTime.isFinite,
                  part.startTime == priorEnd,
                  part.endTime > part.startTime,
                  part.endTime <= source.endTime
            else { return false }
            priorEnd = part.endTime
        }
        return priorEnd == source.endTime
    }

    static func mergedTargets(
        _ targetIDs: [UUID],
        segmentByID: [UUID: TranscriptSegment],
        indexByID: [UUID: Int]
    ) -> [TranscriptSegment]? {
        let indices = targetIDs.compactMap { indexByID[$0] }
        guard targetIDs.count >= 2,
              indices.count == targetIDs.count,
              indices == indices.sorted(),
              indices == Array(indices[0]...indices[indices.count - 1])
        else { return nil }
        let targets = targetIDs.compactMap { segmentByID[$0] }
        guard Set(targets.map(\.speakerID)).count == 1,
              Set(targets.map(\.channel)).count == 1,
              zip(targets, targets.dropFirst()).allSatisfy({ pair in
                  pair.0.endTime <= pair.1.startTime
              })
        else { return nil }
        return targets
    }
}
