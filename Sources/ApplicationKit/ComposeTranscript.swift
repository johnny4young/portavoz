import Foundation
import PortavozCore

/// Downstream consumers must opt into corrected rows explicitly.
public enum TranscriptReadingPolicy: Sendable, Equatable {
    case accepted
    case composed
}

/// Both immutable readings produced by one composition pass.
public struct TranscriptComposition: Sendable, Equatable {
    public let accepted: MeetingTranscriptContent
    public let composed: MeetingTranscriptContent

    public init(
        accepted: MeetingTranscriptContent,
        composed: MeetingTranscriptContent
    ) {
        self.accepted = accepted
        self.composed = composed
    }

    public func content(for policy: TranscriptReadingPolicy) -> MeetingTranscriptContent {
        switch policy {
        case .accepted: accepted
        case .composed: composed
        }
    }
}

public enum ComposeTranscriptError: Error, Equatable, LocalizedError, Sendable {
    case invalidBaseRevision(Int)
    case unspecifiedBaseMaterial
    case invalidBaseSegments
    case duplicateCorrectionID(UUID)
    case invalidCreatedAt(UUID)
    case invalidEventMetadata(UUID)
    case wrongMeeting(UUID)
    case staleCorrection(UUID, expected: Int, actual: Int)
    case invalidTargets(UUID)
    case missingTarget(UUID, UUID)
    case invalidSupersession(UUID)
    case branchedSupersession(UUID)
    case supersessionTargetMismatch(UUID)
    case overlappingTarget(UUID, UUID, UUID)
    case invalidReplacement(UUID)
    case invalidSplit(UUID)
    case invalidMerge(UUID)
    case restoreWithoutSupersession(UUID)
    case duplicateComposedRowID(UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseRevision:
            "The accepted transcript revision is invalid."
        case .unspecifiedBaseMaterial:
            "Correction composition requires an explicit raw or refined base."
        case .invalidBaseSegments:
            "The accepted transcript contains invalid or ambiguous segments."
        case .duplicateCorrectionID:
            "Two transcript corrections use the same identity."
        case .invalidCreatedAt:
            "A transcript correction has an invalid creation time."
        case .invalidEventMetadata:
            "A transcript correction has invalid portable metadata."
        case .wrongMeeting:
            "A transcript correction belongs to another meeting."
        case .staleCorrection:
            "A transcript correction does not match the accepted revision."
        case .invalidTargets:
            "A transcript correction has invalid, empty, or repeated targets."
        case .missingTarget:
            "A transcript correction targets a segment that is not accepted."
        case .invalidSupersession:
            "A transcript correction has an invalid supersession link."
        case .branchedSupersession:
            "More than one transcript correction supersedes the same event."
        case .supersessionTargetMismatch:
            "A superseding correction must target the same accepted segments."
        case .overlappingTarget:
            "Two active transcript corrections target the same segment."
        case .invalidReplacement:
            "Replacement transcript text must contain spoken content."
        case .invalidSplit:
            "A split correction must contain ordered, valid parts."
        case .invalidMerge:
            "A merge correction requires adjacent compatible segments."
        case .restoreWithoutSupersession:
            "A restore correction must supersede an earlier correction."
        case .duplicateComposedRowID:
            "A correction would create an ambiguous transcript row identity."
        }
    }
}

/// Pure correction composer over immutable accepted transcript segments.
public struct ComposeTranscript: Sendable {
    public init() {}

    public func execute(
        baseTranscriptRevision: Int,
        baseMaterial: MeetingTranscriptBaseMaterial,
        segments: [TranscriptSegment],
        chapterTitles: [TimeInterval: String] = [:],
        corrections: [TranscriptCorrectionEvent]
    ) throws -> TranscriptComposition {
        guard baseTranscriptRevision >= 0 else {
            throw ComposeTranscriptError.invalidBaseRevision(baseTranscriptRevision)
        }
        guard baseMaterial != .unspecified else {
            throw ComposeTranscriptError.unspecifiedBaseMaterial
        }

        let orderedSegments = try validateAndOrder(segments)
        let accepted = MeetingTranscriptContent.accepted(
            baseTranscriptRevision: baseTranscriptRevision,
            segments: orderedSegments,
            chapterTitles: chapterTitles,
            baseMaterial: baseMaterial)
        let correctionState = try validatedCorrectionState(
            corrections,
            baseTranscriptRevision: baseTranscriptRevision,
            segments: orderedSegments)
        let rows = try composeRows(
            segments: orderedSegments,
            corrections: correctionState.readingCorrections,
            history: corrections)
        let chapters = composedChapters(
            rows: rows,
            meetingID: orderedSegments.first?.meetingID,
            chapterTitles: chapterTitles)
        let composed = MeetingTranscriptContent(
            baseTranscriptRevision: baseTranscriptRevision,
            rows: rows,
            chapters: chapters,
            lineage: MeetingTranscriptLineage(
                baseMaterial: baseMaterial,
                projection: .composed,
                activeCorrectionIDs: correctionState.lineageCorrectionIDs))
        return TranscriptComposition(accepted: accepted, composed: composed)
    }
}

private extension ComposeTranscript {
    func validateAndOrder(
        _ segments: [TranscriptSegment]
    ) throws -> [TranscriptSegment] {
        let meetings = Set(segments.map(\.meetingID))
        let identifiers = Set(segments.map(\.id))
        guard meetings.count <= 1,
              identifiers.count == segments.count,
              segments.allSatisfy({ segment in
                  segment.startTime.isFinite
                      && segment.endTime.isFinite
                      && segment.startTime >= 0
                      && segment.endTime >= segment.startTime
                      && segment.isFinal
                      && (segment.confidence.map {
                          $0.isFinite && (0 ... 1).contains($0)
                      } ?? true)
              })
        else { throw ComposeTranscriptError.invalidBaseSegments }
        return segments.sorted(by: segmentPrecedes)
    }

    struct ValidatedCorrectionState {
        let readingCorrections: [TranscriptCorrectionEvent]
        let lineageCorrectionIDs: [UUID]
    }

    func validatedCorrectionState(
        _ corrections: [TranscriptCorrectionEvent],
        baseTranscriptRevision: Int,
        segments: [TranscriptSegment]
    ) throws -> ValidatedCorrectionState {
        let correctionsByID = try indexCorrections(corrections)
        let sourceIDs = Set(segments.map(\.id))
        let correctionsByIdentity = corrections.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        try validateCorrectionInputs(
            correctionsByIdentity,
            baseTranscriptRevision: baseTranscriptRevision,
            meetingID: segments.first?.meetingID,
            sourceIDs: sourceIDs)
        let orderedCorrections = corrections.sorted(by: correctionPrecedes)
        let superseded = try supersededCorrectionIDs(
            orderedCorrections,
            correctionsByID: correctionsByID)
        let indexBySourceID = Dictionary(
            uniqueKeysWithValues: segments.enumerated().map { ($0.element.id, $0.offset) })
        let terminal = orderedCorrections
            .filter { !superseded.contains($0.id) && $0.deletedAt == nil }
            .sorted { lhs, rhs in
                let lhsIndex = lhs.targetSegmentIDs.compactMap { indexBySourceID[$0] }.min() ?? 0
                let rhsIndex = rhs.targetSegmentIDs.compactMap { indexBySourceID[$0] }.min() ?? 0
                if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
                return correctionPrecedes(lhs, rhs)
            }
        let readingCorrections = terminal.filter {
            if case .restore = $0.kind { return false }
            return true
        }
        try validateActiveCorrections(
            readingCorrections,
            history: orderedCorrections,
            segments: segments,
            indexBySourceID: indexBySourceID)
        try validateGeneratedRowIDs(readingCorrections, sourceIDs: sourceIDs)
        return ValidatedCorrectionState(
            readingCorrections: readingCorrections,
            lineageCorrectionIDs: terminal.map(\.id))
    }

    func indexCorrections(
        _ corrections: [TranscriptCorrectionEvent]
    ) throws -> [UUID: TranscriptCorrectionEvent] {
        let grouped = Dictionary(grouping: corrections, by: \.id)
        let duplicate = grouped
            .filter { $0.value.count > 1 }
            .map(\.key)
            .min { $0.uuidString < $1.uuidString }
        if let duplicate {
            throw ComposeTranscriptError.duplicateCorrectionID(duplicate)
        }
        return grouped.mapValues { $0[0] }
    }

    func validateCorrectionInputs(
        _ corrections: [TranscriptCorrectionEvent],
        baseTranscriptRevision: Int,
        meetingID: MeetingID?,
        sourceIDs: Set<UUID>
    ) throws {
        for correction in corrections {
            guard correction.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw ComposeTranscriptError.invalidCreatedAt(correction.id)
            }
            let deletedAtIsValid = correction.deletedAt.map { deletedAt in
                deletedAt.timeIntervalSinceReferenceDate.isFinite
                    && deletedAt >= correction.createdAt
                    && deletedAt <= correction.updatedAt
            } ?? true
            guard correction.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                  correction.updatedAt >= correction.createdAt,
                  deletedAtIsValid
            else { throw ComposeTranscriptError.invalidEventMetadata(correction.id) }
            if let meetingID, correction.meetingID != meetingID {
                throw ComposeTranscriptError.wrongMeeting(correction.id)
            }
            guard correction.baseTranscriptRevision == baseTranscriptRevision else {
                throw ComposeTranscriptError.staleCorrection(
                    correction.id,
                    expected: baseTranscriptRevision,
                    actual: correction.baseTranscriptRevision)
            }
            let targets = Set(correction.targetSegmentIDs)
            guard !targets.isEmpty, targets.count == correction.targetSegmentIDs.count else {
                throw ComposeTranscriptError.invalidTargets(correction.id)
            }
            if let missing = correction.targetSegmentIDs.first(where: { !sourceIDs.contains($0) }) {
                throw ComposeTranscriptError.missingTarget(correction.id, missing)
            }
            if case .restore = correction.kind,
               correction.supersedesCorrectionID == nil {
                throw ComposeTranscriptError.restoreWithoutSupersession(correction.id)
            }
        }
    }

    func supersededCorrectionIDs(
        _ corrections: [TranscriptCorrectionEvent],
        correctionsByID: [UUID: TranscriptCorrectionEvent]
    ) throws -> Set<UUID> {
        var successorByPredecessor: [UUID: UUID] = [:]
        var superseded = Set<UUID>()
        for correction in corrections {
            guard let predecessorID = correction.supersedesCorrectionID else { continue }
            guard let predecessor = correctionsByID[predecessorID],
                  predecessor.id != correction.id,
                  correctionPrecedes(predecessor, correction)
            else { throw ComposeTranscriptError.invalidSupersession(correction.id) }
            if successorByPredecessor.updateValue(
                correction.id,
                forKey: predecessorID) != nil {
                throw ComposeTranscriptError.branchedSupersession(predecessorID)
            }
            guard predecessor.targetSegmentIDs == correction.targetSegmentIDs else {
                throw ComposeTranscriptError.supersessionTargetMismatch(correction.id)
            }
            superseded.insert(predecessorID)
        }
        return superseded
    }

    func validateActiveCorrections(
        _ active: [TranscriptCorrectionEvent],
        history: [TranscriptCorrectionEvent],
        segments: [TranscriptSegment],
        indexBySourceID: [UUID: Int]
    ) throws {
        var ownersByTarget: [UUID: [TranscriptCorrectionDomain: UUID]] = [:]
        for correction in active {
            let domain: TranscriptCorrectionDomain
            do {
                domain = try TranscriptCorrectionPolicy.correctionDomain(
                    of: correction,
                    in: history)
            } catch {
                throw ComposeTranscriptError.invalidSupersession(correction.id)
            }
            for target in correction.targetSegmentIDs {
                var owners = ownersByTarget[target, default: [:]]
                let existing = domain == .structure
                    ? owners.values.first
                    : owners[domain] ?? owners[.structure]
                if let existing {
                    throw ComposeTranscriptError.overlappingTarget(
                        target,
                        existing,
                        correction.id)
                }
                owners[domain] = correction.id
                ownersByTarget[target] = owners
            }
            try validateKind(
                correction,
                segments: segments,
                indexBySourceID: indexBySourceID)
        }
    }

    func validateKind(
        _ correction: TranscriptCorrectionEvent,
        segments: [TranscriptSegment],
        indexBySourceID: [UUID: Int]
    ) throws {
        let orderedTargets = correction.targetSegmentIDs.compactMap { indexBySourceID[$0] }
        let sortedTargets = orderedTargets.sorted()
        switch correction.kind {
        case .replaceText(let text, _):
            guard orderedTargets.count == 1,
                  TranscriptContentPolicy.hasLexicalContent(text)
            else {
                throw ComposeTranscriptError.invalidReplacement(correction.id)
            }
        case .changeSpeaker:
            guard orderedTargets.count == 1 else {
                throw ComposeTranscriptError.invalidTargets(correction.id)
            }
        case .split(let parts):
            guard orderedTargets.count == 1,
                  parts.count >= 2,
                  Set(parts.map(\.id)).count == parts.count,
                  let source = orderedTargets.first.map({ segments[$0] }),
                  splitIsValid(parts, inside: source)
            else { throw ComposeTranscriptError.invalidSplit(correction.id) }
        case .merge(let replacementText, _):
            let targetSegments = sortedTargets.map { segments[$0] }
            guard orderedTargets.count >= 2,
                  orderedTargets == sortedTargets,
                  sortedTargets == Array(
                      sortedTargets[0]...sortedTargets[sortedTargets.count - 1]),
                  Set(targetSegments.map(\.speakerID)).count == 1,
                  Set(targetSegments.map(\.channel.rawValue)).count == 1,
                  zip(targetSegments, targetSegments.dropFirst()).allSatisfy({ pair in
                      pair.0.endTime <= pair.1.startTime
                  }),
                  replacementText.map(TranscriptContentPolicy.hasLexicalContent) ?? true
            else { throw ComposeTranscriptError.invalidMerge(correction.id) }
        case .suppress:
            guard orderedTargets.count == 1 else {
                throw ComposeTranscriptError.invalidTargets(correction.id)
            }
        case .restore:
            break
        }
    }

    func splitIsValid(
        _ parts: [TranscriptCorrectionPart],
        inside source: TranscriptSegment
    ) -> Bool {
        var priorEnd = source.startTime
        for (index, part) in parts.enumerated() {
            guard TranscriptContentPolicy.hasLexicalContent(part.text),
                  part.startTime.isFinite,
                  part.endTime.isFinite,
                  part.startTime == priorEnd,
                  part.endTime > part.startTime,
                  part.endTime <= source.endTime
            else { return false }
            if index == 0, part.startTime != source.startTime { return false }
            priorEnd = part.endTime
        }
        return priorEnd == source.endTime
    }

    func validateGeneratedRowIDs(
        _ corrections: [TranscriptCorrectionEvent],
        sourceIDs: Set<UUID>
    ) throws {
        let generatedIDs = corrections.flatMap { correction -> [UUID] in
            switch correction.kind {
            case .replaceText, .changeSpeaker, .merge:
                [correction.id]
            case .split(let parts):
                parts.map(\.id)
            case .suppress, .restore:
                []
            }
        }
        let grouped = Dictionary(grouping: generatedIDs, by: { $0 })
        let duplicate = grouped
            .filter { $0.value.count > 1 }
            .map(\.key)
            .min { $0.uuidString < $1.uuidString }
        if let duplicate {
            throw ComposeTranscriptError.duplicateComposedRowID(duplicate)
        }
        if let collision = generatedIDs.first(where: sourceIDs.contains) {
            throw ComposeTranscriptError.duplicateComposedRowID(collision)
        }
    }

    func composeRows(
        segments: [TranscriptSegment],
        corrections: [TranscriptCorrectionEvent],
        history: [TranscriptCorrectionEvent]
    ) throws -> [MeetingTranscriptContent.Row] {
        let segmentByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        let indexByID = Dictionary(
            uniqueKeysWithValues: segments.enumerated().map { ($0.element.id, $0.offset) })
        let correctionsByTarget = Dictionary(grouping: corrections.flatMap { correction in
            correction.targetSegmentIDs.map { ($0, correction) }
        }, by: \.0).mapValues { $0.map(\.1).sorted(by: correctionPrecedes) }
        var domainByCorrectionID: [UUID: TranscriptCorrectionDomain] = [:]
        for correction in corrections {
            do {
                domainByCorrectionID[correction.id] = try TranscriptCorrectionPolicy
                    .correctionDomain(of: correction, in: history)
            } catch {
                throw ComposeTranscriptError.invalidSupersession(correction.id)
            }
        }
        var rows: [MeetingTranscriptContent.Row] = []
        var consumed = Set<UUID>()

        for segment in segments where !consumed.contains(segment.id) {
            guard let targetCorrections = correctionsByTarget[segment.id],
                  !targetCorrections.isEmpty
            else {
                rows.append(row(from: segment))
                continue
            }
            if let structural = targetCorrections.first(where: {
                domainByCorrectionID[$0.id] == .structure
            }) {
                let targetSet = Set(structural.targetSegmentIDs)
                let targetSegments = structural.targetSegmentIDs
                    .sorted { (indexByID[$0] ?? 0) < (indexByID[$1] ?? 0) }
                    .compactMap { segmentByID[$0] }
                consumed.formUnion(targetSet)
                rows.append(contentsOf: correctedRows(
                    for: structural,
                    targetSegments: targetSegments))
            } else {
                rows.append(propertyCorrectedRow(
                    source: segment,
                    corrections: targetCorrections,
                    domainByCorrectionID: domainByCorrectionID))
            }
        }
        return rows
    }

    func propertyCorrectedRow(
        source: TranscriptSegment,
        corrections: [TranscriptCorrectionEvent],
        domainByCorrectionID: [UUID: TranscriptCorrectionDomain]
    ) -> MeetingTranscriptContent.Row {
        var text = source.text
        var language = source.language
        var speakerID = source.speakerID
        var confidence = source.confidence
        var effectiveCorrections: [TranscriptCorrectionEvent] = []

        for correction in corrections {
            switch correction.kind {
            case .replaceText(let replacement, let replacementLanguage):
                text = replacement
                language = replacementLanguage ?? source.language
                confidence = nil
                effectiveCorrections.append(correction)
            case .changeSpeaker(let replacementSpeakerID):
                speakerID = replacementSpeakerID
                effectiveCorrections.append(correction)
            case .restore:
                switch domainByCorrectionID[correction.id] {
                case .text:
                    text = source.text
                    language = source.language
                    confidence = source.confidence
                case .speaker:
                    speakerID = source.speakerID
                case .structure, .none:
                    break
                }
            case .split, .merge, .suppress:
                break
            }
        }

        return row(
            id: effectiveCorrections.last?.id ?? source.id,
            sources: [source],
            text: text,
            speakerID: speakerID,
            language: language,
            confidence: confidence)
    }

    func correctedRows(
        for correction: TranscriptCorrectionEvent,
        targetSegments: [TranscriptSegment]
    ) -> [MeetingTranscriptContent.Row] {
        switch correction.kind {
        case .replaceText(let text, let language):
            return [row(
                id: correction.id,
                sources: targetSegments,
                text: text,
                speakerID: targetSegments[0].speakerID,
                language: language ?? targetSegments[0].language,
                confidence: nil)]
        case .changeSpeaker(let speakerID):
            return [row(
                id: correction.id,
                sources: targetSegments,
                text: targetSegments[0].text,
                speakerID: speakerID,
                language: targetSegments[0].language,
                confidence: targetSegments[0].confidence)]
        case .split(let parts):
            return splitRows(parts, source: targetSegments[0])
        case .merge(let replacementText, let language):
            return [mergedRow(
                correctionID: correction.id,
                targetSegments: targetSegments,
                replacementText: replacementText,
                language: language)]
        case .suppress:
            return []
        case .restore:
            return targetSegments.map(row(from:))
        }
    }

    func splitRows(
        _ parts: [TranscriptCorrectionPart],
        source: TranscriptSegment
    ) -> [MeetingTranscriptContent.Row] {
        parts.map { part in
            MeetingTranscriptContent.Row(
                id: part.id,
                sourceSegmentIDs: [source.id],
                speakerID: part.speakerID,
                channel: source.channel,
                text: part.text,
                language: part.language,
                startTime: part.startTime,
                endTime: part.endTime,
                confidence: nil,
                isFinal: true)
        }
    }

    func mergedRow(
        correctionID: UUID,
        targetSegments: [TranscriptSegment],
        replacementText: String?,
        language: String?
    ) -> MeetingTranscriptContent.Row {
        let candidateLanguage = targetSegments[0].language
        let commonLanguage = targetSegments.allSatisfy { $0.language == candidateLanguage }
            ? candidateLanguage
            : nil
        let sourceConfidence = targetSegments.allSatisfy { $0.confidence != nil }
            ? targetSegments.compactMap(\.confidence).min()
            : nil
        return row(
            id: correctionID,
            sources: targetSegments,
            text: replacementText ?? targetSegments.map(\.text).joined(separator: " "),
            speakerID: targetSegments[0].speakerID,
            language: language ?? commonLanguage,
            confidence: replacementText == nil ? sourceConfidence : nil)
    }

    func row(from segment: TranscriptSegment) -> MeetingTranscriptContent.Row {
        MeetingTranscriptContent.Row(
            id: segment.id,
            sourceSegmentIDs: [segment.id],
            speakerID: segment.speakerID,
            channel: segment.channel,
            text: segment.text,
            language: segment.language,
            startTime: segment.startTime,
            endTime: segment.endTime,
            confidence: segment.confidence,
            isFinal: segment.isFinal)
    }

    func row(
        id: UUID,
        sources: [TranscriptSegment],
        text: String,
        speakerID: SpeakerID?,
        language: String?,
        confidence: Double?
    ) -> MeetingTranscriptContent.Row {
        MeetingTranscriptContent.Row(
            id: id,
            sourceSegmentIDs: sources.map(\.id),
            speakerID: speakerID,
            channel: sources[0].channel,
            text: text,
            language: language,
            startTime: sources.map(\.startTime).min() ?? 0,
            endTime: sources.map(\.endTime).max() ?? 0,
            confidence: confidence,
            isFinal: true)
    }

    func composedChapters(
        rows: [MeetingTranscriptContent.Row],
        meetingID: MeetingID?,
        chapterTitles: [TimeInterval: String]
    ) -> [MeetingTranscriptContent.Chapter] {
        guard let meetingID else { return [] }
        let segments = rows.map { row in
            TranscriptSegment(
                id: row.id,
                meetingID: meetingID,
                speakerID: row.speakerID,
                channel: row.channel,
                text: row.text,
                language: row.language,
                startTime: row.startTime,
                endTime: row.endTime,
                confidence: row.confidence,
                isFinal: row.isFinal)
        }
        return ChapterExtractor.chapters(from: segments).map { chapter in
            MeetingTranscriptContent.Chapter(
                startTime: chapter.startTime,
                title: chapterTitles[chapter.startTime] ?? chapter.title)
        }
    }

    func segmentPrecedes(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        if lhs.endTime != rhs.endTime { return lhs.endTime < rhs.endTime }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    func correctionPrecedes(
        _ lhs: TranscriptCorrectionEvent,
        _ rhs: TranscriptCorrectionEvent
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
