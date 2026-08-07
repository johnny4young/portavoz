import Foundation
import PortavozCore

public enum TranscriptMergeDirection: String, Sendable, Equatable {
    case previous
    case next
}

public struct TranscriptMergeCandidate: Sendable, Equatable, Identifiable {
    public let direction: TranscriptMergeDirection
    public let rows: [MeetingTranscriptContent.Row]

    public init(
        direction: TranscriptMergeDirection,
        rows: [MeetingTranscriptContent.Row]
    ) {
        self.direction = direction
        self.rows = rows
    }

    public var id: UUID {
        switch direction {
        case .previous: rows.first?.id ?? UUID.zero
        case .next: rows.last?.id ?? UUID.zero
        }
    }
}

public struct TranscriptStructuralCorrectionContext: Sendable, Equatable, Identifiable {
    public let current: MeetingTranscriptContent.Row?
    public let originals: [MeetingTranscriptContent.Row]
    public let history: [TranscriptCorrectionEvent]
    public let activeCorrection: TranscriptCorrectionEvent?
    public let mergeCandidates: [TranscriptMergeCandidate]
    public let hasIncompatibleCorrection: Bool

    public init(
        current: MeetingTranscriptContent.Row?,
        originals: [MeetingTranscriptContent.Row],
        history: [TranscriptCorrectionEvent],
        activeCorrection: TranscriptCorrectionEvent?,
        mergeCandidates: [TranscriptMergeCandidate],
        hasIncompatibleCorrection: Bool
    ) {
        self.current = current
        self.originals = originals
        self.history = history
        self.activeCorrection = activeCorrection
        self.mergeCandidates = mergeCandidates
        self.hasIncompatibleCorrection = hasIncompatibleCorrection
    }

    public var id: UUID {
        activeCorrection?.id ?? current?.id ?? originals.first?.id ?? UUID.zero
    }

    public var canSplit: Bool {
        activeCorrection == nil
            && !hasIncompatibleCorrection
            && originals.count == 1
            && originals[0].endTime > originals[0].startTime
    }

    public var canSuppress: Bool {
        activeCorrection == nil
            && !hasIncompatibleCorrection
            && originals.count == 1
    }

    public var isSuppressed: Bool {
        guard current == nil, let activeCorrection else { return false }
        if case .suppress = activeCorrection.kind { return true }
        return false
    }
}

public extension MeetingReviewReadModel {
    func acceptedTranscriptContent(
        chapterTitles: [TimeInterval: String] = [:]
    ) -> MeetingTranscriptContent {
        MeetingTranscriptContent.accepted(
            baseTranscriptRevision: meeting.transcriptRevision,
            segments: segments,
            chapterTitles: chapterTitles,
            baseMaterial: core.isRefinedTranscript ? .refined : .raw)
    }

    /// Precomputes structural editor state once for one Meeting Detail
    /// snapshot. Row presentation then performs constant-time lookups instead
    /// of rebuilding correction ownership across the whole transcript.
    func transcriptStructureProjection(
        current: MeetingTranscriptContent,
        accepted: MeetingTranscriptContent
    ) -> MeetingTranscriptStructureProjection {
        MeetingTranscriptStructureProjection(
            current: current,
            accepted: accepted,
            corrections: corrections,
            transcriptRevision: meeting.transcriptRevision)
    }
}

/// Immutable structural-editor projection for one accepted/composed pair.
/// Its accepted value is also the exact snapshot sent back to the command.
public struct MeetingTranscriptStructureProjection: Sendable, Equatable {
    public let accepted: MeetingTranscriptContent
    public let suppressedContexts: [TranscriptStructuralCorrectionContext]

    private let contextsByRowID: [UUID: TranscriptStructuralCorrectionContext]

    fileprivate init(
        current: MeetingTranscriptContent,
        accepted: MeetingTranscriptContent,
        corrections: [TranscriptCorrectionEvent],
        transcriptRevision: Int
    ) {
        self.accepted = accepted
        let builder = TranscriptStructureProjectionBuilder(
            accepted: accepted,
            corrections: corrections,
            transcriptRevision: transcriptRevision)
        contextsByRowID = Dictionary(uniqueKeysWithValues: current.rows.compactMap { row in
            builder.context(current: row, sourceIDs: row.sourceSegmentIDs).map {
                (row.id, $0)
            }
        })
        suppressedContexts = builder.suppressedContexts()
    }

    public func context(
        for current: MeetingTranscriptContent.Row
    ) -> TranscriptStructuralCorrectionContext? {
        contextsByRowID[current.id]
    }
}

public enum TranscriptStructuralCorrectionOperation: Sendable, Equatable {
    case split(
        sourceSegmentID: UUID,
        firstText: String,
        secondText: String,
        splitTime: TimeInterval)
    case merge(sourceSegmentIDs: [UUID])
    case suppress(sourceSegmentID: UUID)
    case restore(correctionID: UUID)
}

private struct TranscriptSplitDraft {
    let sourceID: UUID
    let firstText: String
    let secondText: String
    let splitTime: TimeInterval
}

private struct TranscriptStructureProjectionBuilder {
    let acceptedRows: [MeetingTranscriptContent.Row]
    let acceptedByID: [UUID: MeetingTranscriptContent.Row]
    let acceptedIndexByID: [UUID: Int]
    let currentHistory: [TranscriptCorrectionEvent]
    let historyByTarget: [UUID: [TranscriptCorrectionEvent]]
    let activeByTarget: [UUID: [TranscriptCorrectionEvent]]
    let activeDomains: [UUID: TranscriptCorrectionDomain]
    let effectiveActiveCorrections: [TranscriptCorrectionEvent]

    init(
        accepted: MeetingTranscriptContent,
        corrections: [TranscriptCorrectionEvent],
        transcriptRevision: Int
    ) {
        acceptedRows = accepted.rows
        acceptedByID = Dictionary(uniqueKeysWithValues: accepted.rows.map { ($0.id, $0) })
        acceptedIndexByID = Dictionary(uniqueKeysWithValues:
            accepted.rows.enumerated().map { ($0.element.id, $0.offset) })
        let history = corrections.filter {
            $0.baseTranscriptRevision == transcriptRevision
        }.sorted(by: TranscriptCorrectionPolicy.precedes)
        currentHistory = history
        historyByTarget = Self.eventsByTarget(history)

        let superseded = Set(history.compactMap(\.supersedesCorrectionID))
        let terminal = history.filter {
            $0.deletedAt == nil && !superseded.contains($0.id)
        }
        let active = terminal.filter {
            if case .restore = $0.kind { return false }
            return true
        }
        effectiveActiveCorrections = active
        activeByTarget = Self.eventsByTarget(active)
        let domains = TranscriptCorrectionDomainIndex(history: history)
        activeDomains = Dictionary(uniqueKeysWithValues:
            active.compactMap { event in
                (try? domains.domain(of: event)).map { (event.id, $0) }
            })
    }

    func context(
        current: MeetingTranscriptContent.Row?,
        sourceIDs: [UUID],
        knownActiveCorrection: TranscriptCorrectionEvent? = nil
    ) -> TranscriptStructuralCorrectionContext? {
        let sourceSet = Set(sourceIDs)
        let originals = sourceIDs.compactMap { acceptedByID[$0] }
        guard originals.count == sourceSet.count, !originals.isEmpty else { return nil }
        let history = events(for: sourceIDs, in: historyByTarget)
        let overlappingActive = events(for: sourceIDs, in: activeByTarget)
        let active = knownActiveCorrection ?? overlappingActive.first { event in
            guard Set(event.targetSegmentIDs) == sourceSet else { return false }
            return activeDomains[event.id] == .structure
        }
        let hasIncompatibleCorrection = active == nil && !overlappingActive.isEmpty
        return TranscriptStructuralCorrectionContext(
            current: current,
            originals: originals,
            history: history,
            activeCorrection: active,
            mergeCandidates: active == nil && sourceIDs.count == 1
                ? mergeCandidates(for: sourceIDs[0])
                : [],
            hasIncompatibleCorrection: hasIncompatibleCorrection)
    }

    func suppressedContexts() -> [TranscriptStructuralCorrectionContext] {
        effectiveActiveCorrections.compactMap { event in
            guard case .suppress = event.kind else { return nil }
            return context(
                current: nil,
                sourceIDs: event.targetSegmentIDs,
                knownActiveCorrection: event)
        }.sorted { lhs, rhs in
            let lhsIndex = lhs.originals.compactMap { acceptedIndexByID[$0.id] }.min()
                ?? Int.max
            let rhsIndex = rhs.originals.compactMap { acceptedIndexByID[$0.id] }.min()
                ?? Int.max
            if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func mergeCandidates(for sourceID: UUID) -> [TranscriptMergeCandidate] {
        guard let index = acceptedIndexByID[sourceID],
              !hasEffectiveCorrection(sourceID)
        else { return [] }
        let source = acceptedRows[index]
        var candidates: [TranscriptMergeCandidate] = []
        if index > acceptedRows.startIndex {
            let previous = acceptedRows[index - 1]
            if mergeCompatible(previous, source), !hasEffectiveCorrection(previous.id) {
                candidates.append(TranscriptMergeCandidate(
                    direction: .previous,
                    rows: [previous, source]))
            }
        }
        if index + 1 < acceptedRows.endIndex {
            let next = acceptedRows[index + 1]
            if mergeCompatible(source, next), !hasEffectiveCorrection(next.id) {
                candidates.append(TranscriptMergeCandidate(
                    direction: .next,
                    rows: [source, next]))
            }
        }
        return candidates
    }

    func hasEffectiveCorrection(_ sourceID: UUID) -> Bool {
        !(activeByTarget[sourceID]?.isEmpty ?? true)
    }

    func mergeCompatible(
        _ lhs: MeetingTranscriptContent.Row,
        _ rhs: MeetingTranscriptContent.Row
    ) -> Bool {
        lhs.speakerID == rhs.speakerID
            && lhs.channel == rhs.channel
            && lhs.endTime <= rhs.startTime
    }

    func events(
        for sourceIDs: [UUID],
        in index: [UUID: [TranscriptCorrectionEvent]]
    ) -> [TranscriptCorrectionEvent] {
        var seen = Set<UUID>()
        return sourceIDs.flatMap { index[$0] ?? [] }
            .filter { seen.insert($0.id).inserted }
            .sorted(by: TranscriptCorrectionPolicy.precedes)
    }

    static func eventsByTarget(
        _ events: [TranscriptCorrectionEvent]
    ) -> [UUID: [TranscriptCorrectionEvent]] {
        Dictionary(grouping: events.flatMap { event in
            event.targetSegmentIDs.map { ($0, event) }
        }, by: \.0).mapValues {
            $0.map(\.1).sorted(by: TranscriptCorrectionPolicy.precedes)
        }
    }
}

private extension UUID {
    static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

public struct RestructureMeetingTranscriptRequest: Sendable, Equatable {
    public let meetingID: MeetingID
    public let baseTranscriptRevision: Int
    public let accepted: MeetingTranscriptContent
    public let operation: TranscriptStructuralCorrectionOperation

    public init(
        meetingID: MeetingID,
        baseTranscriptRevision: Int,
        accepted: MeetingTranscriptContent,
        operation: TranscriptStructuralCorrectionOperation
    ) {
        self.meetingID = meetingID
        self.baseTranscriptRevision = baseTranscriptRevision
        self.accepted = accepted
        self.operation = operation
    }
}

public enum RestructureMeetingTranscriptError: Error, Equatable, LocalizedError, Sendable {
    case invalidAcceptedTranscript
    case staleTranscript
    case invalidTarget
    case invalidSplit
    case invalidMerge
    case incompatibleCorrection
    case correctionNoLongerActive

    public var errorDescription: String? {
        switch self {
        case .invalidAcceptedTranscript:
            "The accepted transcript cannot be edited safely."
        case .staleTranscript:
            "The transcript changed before this correction was saved."
        case .invalidTarget:
            "The selected transcript line is no longer available."
        case .invalidSplit:
            "A split needs two spoken parts and a time inside the selected line."
        case .invalidMerge:
            "Only adjacent lines from the same speaker and audio channel can be merged."
        case .incompatibleCorrection:
            "Undo the existing correction before changing this line's structure."
        case .correctionNoLongerActive:
            "This structural correction has already been restored or replaced."
        }
    }
}

public struct RestructureMeetingTranscriptResult: Sendable, Equatable {
    public let event: TranscriptCorrectionEvent

    public init(event: TranscriptCorrectionEvent) {
        self.event = event
    }
}

/// Owns structural transcript edits over one explicit accepted snapshot.
/// Persistence remains append-only: hiding never deletes source evidence and
/// undo appends a restore event that points to the current structural event.
public struct RestructureMeetingTranscript: ApplicationUseCase {
    private let repository: any TranscriptCorrectionRepository
    private let sourceDeviceID: UUID
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    public init(
        repository: any TranscriptCorrectionRepository,
        sourceDeviceID: UUID,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.repository = repository
        self.sourceDeviceID = sourceDeviceID
        self.now = now
        self.makeID = makeID
    }

    public func execute(
        _ request: RestructureMeetingTranscriptRequest
    ) async throws -> RestructureMeetingTranscriptResult {
        let acceptedRows = try validatedAcceptedRows(request)
        let history = try await repository.transcriptCorrectionHistory(
            for: request.meetingID)
        try TranscriptCorrectionPolicy.validateHistory(
            history,
            meetingID: request.meetingID)

        let event = try makeEvent(
            for: request,
            acceptedRows: acceptedRows,
            history: history)
        let persistedEvents = try await repository
            .appendTranscriptCorrections([event])
        guard persistedEvents.count == 1,
              let persisted = persistedEvents.first
        else { throw RestructureMeetingTranscriptError.invalidTarget }
        return RestructureMeetingTranscriptResult(event: persisted)
    }
}

private extension RestructureMeetingTranscript {
    func validatedAcceptedRows(
        _ request: RestructureMeetingTranscriptRequest
    ) throws -> [MeetingTranscriptContent.Row] {
        guard request.baseTranscriptRevision >= 0,
              request.accepted.baseTranscriptRevision == request.baseTranscriptRevision
        else { throw RestructureMeetingTranscriptError.staleTranscript }
        guard request.accepted.lineage.projection == .accepted,
              request.accepted.lineage.baseMaterial != .unspecified,
              Set(request.accepted.rows.map(\.id)).count == request.accepted.rows.count,
              request.accepted.rows.allSatisfy({ row in
                  row.sourceSegmentIDs == [row.id]
                      && row.startTime.isFinite
                      && row.endTime.isFinite
                      && row.startTime >= 0
                      && row.endTime > row.startTime
                      && row.isFinal
              })
        else { throw RestructureMeetingTranscriptError.invalidAcceptedTranscript }
        return request.accepted.rows
    }

    func makeEvent(
        for request: RestructureMeetingTranscriptRequest,
        acceptedRows: [MeetingTranscriptContent.Row],
        history: [TranscriptCorrectionEvent]
    ) throws -> TranscriptCorrectionEvent {
        var reservedIDs = reservedCorrectionIDs(
            acceptedRows: acceptedRows,
            history: history)
        switch request.operation {
        case .split(let sourceID, let firstText, let secondText, let splitTime):
            return try splitEvent(
                request: request,
                draft: TranscriptSplitDraft(
                    sourceID: sourceID,
                    firstText: firstText,
                    secondText: secondText,
                    splitTime: splitTime),
                acceptedRows: acceptedRows,
                history: history,
                reservedIDs: &reservedIDs)

        case .merge(let sourceIDs):
            return try mergeEvent(
                request: request,
                sourceIDs: sourceIDs,
                acceptedRows: acceptedRows,
                history: history,
                reservedIDs: &reservedIDs)

        case .suppress(let sourceID):
            return try suppressEvent(
                request: request,
                sourceID: sourceID,
                acceptedRows: acceptedRows,
                history: history,
                reservedIDs: &reservedIDs)

        case .restore(let correctionID):
            return try restoreEvent(
                request: request,
                correctionID: correctionID,
                history: history,
                reservedIDs: &reservedIDs)
        }
    }

    func reservedCorrectionIDs(
        acceptedRows: [MeetingTranscriptContent.Row],
        history: [TranscriptCorrectionEvent]
    ) -> Set<UUID> {
        var ids = Set(history.map(\.id))
        ids.formUnion(acceptedRows.map(\.id))
        for event in history {
            if case .split(let parts) = event.kind {
                ids.formUnion(parts.map(\.id))
            }
        }
        return ids
    }

    func splitEvent(
        request: RestructureMeetingTranscriptRequest,
        draft: TranscriptSplitDraft,
        acceptedRows: [MeetingTranscriptContent.Row],
        history: [TranscriptCorrectionEvent],
        reservedIDs: inout Set<UUID>
    ) throws -> TranscriptCorrectionEvent {
        let row = try requiredRow(draft.sourceID, in: acceptedRows)
        try requireUncorrected(
            [draft.sourceID],
            revision: request.baseTranscriptRevision,
            history: history)
        let first = draft.firstText.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = draft.secondText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TranscriptContentPolicy.hasLexicalContent(first),
              TranscriptContentPolicy.hasLexicalContent(second),
              draft.splitTime.isFinite,
              draft.splitTime > row.startTime,
              draft.splitTime < row.endTime
        else { throw RestructureMeetingTranscriptError.invalidSplit }
        let firstPartID = try nextUniqueID(excluding: &reservedIDs)
        let secondPartID = try nextUniqueID(excluding: &reservedIDs)
        return try event(
            request: request,
            targets: [draft.sourceID],
            kind: .split([
                TranscriptCorrectionPart(
                    id: firstPartID,
                    text: first,
                    speakerID: row.speakerID,
                    language: row.language,
                    startTime: row.startTime,
                    endTime: draft.splitTime),
                TranscriptCorrectionPart(
                    id: secondPartID,
                    text: second,
                    speakerID: row.speakerID,
                    language: row.language,
                    startTime: draft.splitTime,
                    endTime: row.endTime)
            ]),
            predecessor: restoredPredecessor(
                targets: [draft.sourceID],
                revision: request.baseTranscriptRevision,
                history: history),
            reservedIDs: &reservedIDs)
    }

    func mergeEvent(
        request: RestructureMeetingTranscriptRequest,
        sourceIDs: [UUID],
        acceptedRows: [MeetingTranscriptContent.Row],
        history: [TranscriptCorrectionEvent],
        reservedIDs: inout Set<UUID>
    ) throws -> TranscriptCorrectionEvent {
        guard sourceIDs.count >= 2,
              Set(sourceIDs).count == sourceIDs.count
        else { throw RestructureMeetingTranscriptError.invalidMerge }
        let indexByID = Dictionary(uniqueKeysWithValues:
            acceptedRows.enumerated().map { ($0.element.id, $0.offset) })
        let indexes = sourceIDs.compactMap { indexByID[$0] }
        guard indexes.count == sourceIDs.count,
              indexes == indexes.sorted(),
              indexes == Array(indexes[0]...indexes[indexes.count - 1])
        else { throw RestructureMeetingTranscriptError.invalidMerge }
        let rows = indexes.map { acceptedRows[$0] }
        guard Set(rows.map(\.speakerID)).count == 1,
              Set(rows.map(\.channel)).count == 1,
              zip(rows, rows.dropFirst()).allSatisfy({
                  $0.endTime <= $1.startTime
              })
        else { throw RestructureMeetingTranscriptError.invalidMerge }
        try requireUncorrected(
            sourceIDs,
            revision: request.baseTranscriptRevision,
            history: history)
        let language = rows.allSatisfy { $0.language == rows[0].language }
            ? rows[0].language
            : nil
        return try event(
            request: request,
            targets: sourceIDs,
            kind: .merge(replacementText: nil, language: language),
            predecessor: restoredPredecessor(
                targets: sourceIDs,
                revision: request.baseTranscriptRevision,
                history: history),
            reservedIDs: &reservedIDs)
    }

    func suppressEvent(
        request: RestructureMeetingTranscriptRequest,
        sourceID: UUID,
        acceptedRows: [MeetingTranscriptContent.Row],
        history: [TranscriptCorrectionEvent],
        reservedIDs: inout Set<UUID>
    ) throws -> TranscriptCorrectionEvent {
        _ = try requiredRow(sourceID, in: acceptedRows)
        try requireUncorrected(
            [sourceID],
            revision: request.baseTranscriptRevision,
            history: history)
        return try event(
            request: request,
            targets: [sourceID],
            kind: .suppress,
            predecessor: restoredPredecessor(
                targets: [sourceID],
                revision: request.baseTranscriptRevision,
                history: history),
            reservedIDs: &reservedIDs)
    }

    func restoreEvent(
        request: RestructureMeetingTranscriptRequest,
        correctionID: UUID,
        history: [TranscriptCorrectionEvent],
        reservedIDs: inout Set<UUID>
    ) throws -> TranscriptCorrectionEvent {
        guard let predecessor = effectiveActiveCorrections(
            revision: request.baseTranscriptRevision,
            history: history)
            .first(where: { $0.id == correctionID }),
            (try? TranscriptCorrectionPolicy.correctionDomain(
                of: predecessor,
                in: history)) == .structure
        else { throw RestructureMeetingTranscriptError.correctionNoLongerActive }
        return try event(
            request: request,
            targets: predecessor.targetSegmentIDs,
            kind: .restore,
            predecessor: predecessor,
            reservedIDs: &reservedIDs)
    }

    func requiredRow(
        _ id: UUID,
        in acceptedRows: [MeetingTranscriptContent.Row]
    ) throws -> MeetingTranscriptContent.Row {
        guard let row = acceptedRows.first(where: { $0.id == id }) else {
            throw RestructureMeetingTranscriptError.invalidTarget
        }
        return row
    }

    func requireUncorrected(
        _ targetIDs: [UUID],
        revision: Int,
        history: [TranscriptCorrectionEvent]
    ) throws {
        let targets = Set(targetIDs)
        guard effectiveActiveCorrections(revision: revision, history: history)
            .allSatisfy({ targets.isDisjoint(with: $0.targetSegmentIDs) })
        else { throw RestructureMeetingTranscriptError.incompatibleCorrection }
    }

    func restoredPredecessor(
        targets: [UUID],
        revision: Int,
        history: [TranscriptCorrectionEvent]
    ) -> TranscriptCorrectionEvent? {
        terminalCorrections(revision: revision, history: history)
            .last(where: { event in
                guard event.targetSegmentIDs == targets else { return false }
                if case .restore = event.kind { return true }
                return false
            })
    }

    func effectiveActiveCorrections(
        revision: Int,
        history: [TranscriptCorrectionEvent]
    ) -> [TranscriptCorrectionEvent] {
        terminalCorrections(revision: revision, history: history).filter {
            if case .restore = $0.kind { return false }
            return true
        }
    }

    func terminalCorrections(
        revision: Int,
        history: [TranscriptCorrectionEvent]
    ) -> [TranscriptCorrectionEvent] {
        let superseded = Set(history.compactMap(\.supersedesCorrectionID))
        return history.filter {
            $0.baseTranscriptRevision == revision
                && $0.deletedAt == nil
                && !superseded.contains($0.id)
        }.sorted(by: TranscriptCorrectionPolicy.precedes)
    }

    func event(
        request: RestructureMeetingTranscriptRequest,
        targets: [UUID],
        kind: TranscriptCorrectionKind,
        predecessor: TranscriptCorrectionEvent?,
        reservedIDs: inout Set<UUID>
    ) throws -> TranscriptCorrectionEvent {
        let minimumDate = predecessor.map {
            $0.createdAt.addingTimeInterval(0.001)
        } ?? .distantPast
        return TranscriptCorrectionEvent(
            id: try nextUniqueID(excluding: &reservedIDs),
            meetingID: request.meetingID,
            baseTranscriptRevision: request.baseTranscriptRevision,
            targetSegmentIDs: targets,
            kind: kind,
            sourceDeviceID: sourceDeviceID,
            createdAt: max(now(), minimumDate),
            supersedesCorrectionID: predecessor?.id)
    }

    func nextUniqueID(
        excluding reservedIDs: inout Set<UUID>
    ) throws -> UUID {
        // The production UUID factory is collision-resistant, but injected
        // deterministic factories and imported history still fail closed.
        for _ in 0..<16 {
            let candidate = makeID()
            if reservedIDs.insert(candidate).inserted { return candidate }
        }
        throw RestructureMeetingTranscriptError.invalidTarget
    }
}
