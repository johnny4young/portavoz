import Foundation
import GRDB
import PortavozCore

/// One portable row plus its durable ordering metadata. Device-local columns
/// stay in StorageKit and never enter this value.
public struct MeetingSyncTimed<Value: Codable & Sendable>: Codable, Sendable {
    public let value: Value
    public let createdAt: Date
    public let updatedAt: Date

    public init(value: Value, createdAt: Date, updatedAt: Date) {
        self.value = value
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One immutable summary identity and every portable child that belongs to it.
/// Generation provenance remains device-local and is deliberately absent.
public struct MeetingSyncSummary: Codable, Sendable {
    public let id: UUID
    public let meetingID: MeetingID
    public let recipeID: String
    public let language: String
    public let markdown: String
    public let version: Int
    public let fingerprint: String?
    public let createdAt: Date
    public let actionItems: [MeetingSyncTimed<ActionItem>]
    public let claims: [SummaryClaim]
    public let decisionEvidence: [SummaryDecisionEvidence]
    public let actionItemEvidence: [SummaryActionItemEvidence]

    public init(
        id: UUID,
        meetingID: MeetingID,
        recipeID: String,
        language: String,
        markdown: String,
        version: Int,
        fingerprint: String?,
        createdAt: Date,
        actionItems: [MeetingSyncTimed<ActionItem>],
        claims: [SummaryClaim],
        decisionEvidence: [SummaryDecisionEvidence],
        actionItemEvidence: [SummaryActionItemEvidence]
    ) {
        self.id = id
        self.meetingID = meetingID
        self.recipeID = recipeID
        self.language = language
        self.markdown = markdown
        self.version = version
        self.fingerprint = fingerprint
        self.createdAt = createdAt
        self.actionItems = actionItems
        self.claims = claims
        self.decisionEvidence = decisionEvidence
        self.actionItemEvidence = actionItemEvidence
    }

    var draft: SummaryDraft {
        SummaryDraft(
            meetingID: meetingID,
            recipeID: recipeID,
            language: language,
            markdown: markdown,
            actionItems: actionItems.map(\.value),
            fingerprint: fingerprint,
            claims: claims,
            decisionEvidence: decisionEvidence,
            actionItemEvidence: actionItemEvidence)
    }
}

extension MeetingSyncSummary {
    /// Generated summary content is immutable after its identity is published.
    /// Only task completion metadata and current claim feedback may converge.
    func immutableDifference(from other: MeetingSyncSummary) -> String? {
        guard id == other.id else { return "identity" }
        guard meetingID == other.meetingID else { return "meeting relation" }
        guard recipeID == other.recipeID else { return "recipe" }
        guard language == other.language else { return "language" }
        guard markdown == other.markdown else { return "markdown" }
        guard version == other.version else { return "version" }
        guard fingerprint == other.fingerprint else { return "fingerprint" }
        guard sameMeetingSyncInstant(createdAt, other.createdAt) else {
            return "creation time"
        }

        guard sameMeetingSyncElements(actionItems, other.actionItems, compare: { left, right in
            left.value.id == right.value.id
                && left.value.text == right.value.text
                && left.value.ownerSpeakerID == right.value.ownerSpeakerID
                && sameMeetingSyncInstant(left.createdAt, right.createdAt)
        }) else { return "action item" }
        guard sameMeetingSyncElements(claims, other.claims, compare: { left, right in
            left.id == right.id
                && left.kind == right.kind
                && left.sourceTranscriptRevision == right.sourceTranscriptRevision
                && left.evidenceSegmentIDs == right.evidenceSegmentIDs
                && left.unavailableEvidenceCount == right.unavailableEvidenceCount
        }) else { return "claim" }
        guard sameMeetingSyncElements(
            decisionEvidence,
            other.decisionEvidence,
            compare: { left, right in
                left.id == right.id
                    && left.sectionOrdinal == right.sectionOrdinal
                    && left.bulletOrdinal == right.bulletOrdinal
                    && left.sourceTranscriptRevision == right.sourceTranscriptRevision
                    && left.evidenceSegmentIDs == right.evidenceSegmentIDs
                    && left.unavailableEvidenceCount == right.unavailableEvidenceCount
            }
        ) else { return "decision evidence" }
        guard sameMeetingSyncElements(
            actionItemEvidence,
            other.actionItemEvidence,
            compare: { left, right in
                left.id == right.id
                    && left.actionItemID == right.actionItemID
                    && left.sourceTranscriptRevision == right.sourceTranscriptRevision
                    && left.evidenceSegmentIDs == right.evidenceSegmentIDs
                    && left.unavailableEvidenceCount == right.unavailableEvidenceCount
            }
        ) else { return "action-item evidence" }
        return nil
    }
}

private func sameMeetingSyncElements<Left, Right>(
    _ left: [Left],
    _ right: [Right],
    compare: (Left, Right) -> Bool
) -> Bool {
    left.count == right.count && zip(left, right).allSatisfy(compare)
}

private func sameMeetingSyncInstant(_ left: Date, _ right: Date) -> Bool {
    Int64((left.timeIntervalSince1970 * 1_000).rounded())
        == Int64((right.timeIntervalSince1970 * 1_000).rounded())
}

/// Complete text-first meeting state sent through a sync adapter. It includes
/// every live portable artifact, but never audio, local paths, embeddings,
/// canonical people, model runs, jobs, receipts, secrets, or voiceprints.
public struct MeetingSyncAggregate: Codable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let meeting: MeetingSyncTimed<Meeting>
    public let speakers: [MeetingSyncTimed<Speaker>]
    public let segments: [MeetingSyncTimed<TranscriptSegment>]
    public let summaries: [MeetingSyncSummary]
    public let contextItems: [MeetingSyncTimed<ContextItem>]
    public let companionCards: [MeetingSyncTimed<CompanionCard>]

    public init(
        meeting: MeetingSyncTimed<Meeting>,
        speakers: [MeetingSyncTimed<Speaker>],
        segments: [MeetingSyncTimed<TranscriptSegment>],
        summaries: [MeetingSyncSummary],
        contextItems: [MeetingSyncTimed<ContextItem>],
        companionCards: [MeetingSyncTimed<CompanionCard>]
    ) {
        formatVersion = Self.currentFormatVersion
        self.meeting = meeting
        self.speakers = speakers
        self.segments = segments
        self.summaries = summaries
        self.contextItems = contextItems
        self.companionCards = companionCards
    }
}

public enum MeetingSyncMutation: Codable, Sendable {
    case upsert(MeetingSyncAggregate)
    case delete
}

/// Exact portable state joined to one local journal generation. The pair of
/// source device and generation is stable across retries and unique across
/// devices without placing transport identity in the meeting database rows.
public struct MeetingSyncEnvelope: Codable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let meetingID: MeetingID
    public let sourceDeviceID: UUID
    public let generation: Int
    public let changedAt: Date
    public let mutation: MeetingSyncMutation

    public init(
        meetingID: MeetingID,
        sourceDeviceID: UUID,
        generation: Int,
        changedAt: Date,
        mutation: MeetingSyncMutation
    ) {
        formatVersion = Self.currentFormatVersion
        self.meetingID = meetingID
        self.sourceDeviceID = sourceDeviceID
        self.generation = generation
        self.changedAt = changedAt
        self.mutation = mutation
    }
}

public enum MeetingSyncRemoteApplyResult: Equatable, Sendable {
    case applied
    case localChangePending(generation: Int)
    case deletionWon(discardedLocalGeneration: Int?)
}

extension MeetingStore {
    /// Reads the aggregate and its generation from one database snapshot.
    /// A stale caller must fetch the newest journal item instead of silently
    /// labeling current content with an older generation.
    public func meetingSyncEnvelope(
        for change: MeetingSyncChange,
        sourceDeviceID: UUID
    ) async throws -> MeetingSyncEnvelope {
        try await database.read { db in
            let key = change.meetingID.rawValue.uuidString
            guard let state = try MeetingSyncStateRecord.fetchOne(db, key: key),
                  state.localGeneration == change.generation,
                  state.localGeneration > state.acknowledgedGeneration,
                  state.isDeleted == change.isDeleted
            else {
                throw StorageError.invalidSyncState(
                    "sync envelope must match the newest pending generation")
            }
            let mutation: MeetingSyncMutation
            if state.isDeleted {
                mutation = .delete
            } else {
                guard let aggregate = try Self.meetingSyncAggregate(
                    meetingID: change.meetingID,
                    in: db)
                else {
                    throw StorageError.invalidSyncState(
                        "live journal state has no live meeting aggregate")
                }
                mutation = .upsert(aggregate)
            }
            return MeetingSyncEnvelope(
                meetingID: change.meetingID,
                sourceDeviceID: sourceDeviceID,
                generation: state.localGeneration,
                changedAt: state.changedAt,
                mutation: mutation)
        }
    }

    /// Applies an already authenticated/decoded remote envelope atomically.
    /// Live-on-live concurrency fails closed and leaves local work untouched;
    /// a remote deletion wins but remains recoverable in Recently Deleted.
    public func applyRemoteMeetingSyncEnvelope(
        _ envelope: MeetingSyncEnvelope
    ) async throws -> MeetingSyncRemoteApplyResult {
        guard envelope.formatVersion == MeetingSyncEnvelope.currentFormatVersion,
              envelope.generation > 0
        else {
            throw StorageError.invalidSyncState("unsupported remote sync envelope")
        }
        return try await database.write { db in
            let key = envelope.meetingID.rawValue.uuidString
            let state = try MeetingSyncStateRecord.fetchOne(db, key: key)
            let pendingGeneration = state.flatMap {
                $0.localGeneration > $0.acknowledgedGeneration ? $0.localGeneration : nil
            }

            switch envelope.mutation {
            case .delete:
                try Self.applyRemoteMeetingDeletion(
                    meetingID: envelope.meetingID,
                    changedAt: envelope.changedAt,
                    in: db)
                try Self.settleRemoteMeetingMutation(
                    meetingID: envelope.meetingID,
                    changedAt: envelope.changedAt,
                    isDeleted: true,
                    in: db)
                return pendingGeneration.map {
                    .deletionWon(discardedLocalGeneration: $0)
                } ?? .applied

            case .upsert(let aggregate):
                try Self.validateRemoteMeetingSyncAggregate(
                    aggregate,
                    meetingID: envelope.meetingID)
                if let pendingGeneration {
                    return .localChangePending(generation: pendingGeneration)
                }
                try Self.replaceWithRemoteMeetingSyncAggregate(aggregate, in: db)
                try Self.settleRemoteMeetingMutation(
                    meetingID: envelope.meetingID,
                    changedAt: envelope.changedAt,
                    isDeleted: false,
                    in: db)
                return .applied
            }
        }
    }

    private static func meetingSyncAggregate(
        meetingID: MeetingID,
        in db: Database
    ) throws -> MeetingSyncAggregate? {
        let key = meetingID.rawValue.uuidString
        guard let meetingRecord = try MeetingRecord
            .filter(Column("id") == key)
            .filter(Column("deletedAt") == nil)
            .fetchOne(db)
        else { return nil }

        var meeting = try meetingRecord.meeting
        meeting.audioDirectory = nil
        return MeetingSyncAggregate(
            meeting: MeetingSyncTimed(
                value: meeting,
                createdAt: meetingRecord.createdAt,
                updatedAt: meetingRecord.updatedAt),
            speakers: try meetingSyncSpeakers(meetingKey: key, in: db),
            segments: try meetingSyncSegments(meetingKey: key, in: db),
            summaries: try meetingSyncSummaries(
                meetingID: meetingID,
                meetingKey: key,
                in: db),
            contextItems: try meetingSyncContextItems(meetingKey: key, in: db),
            companionCards: try meetingSyncCompanionCards(meetingKey: key, in: db))
    }

    private static func meetingSyncSpeakers(
        meetingKey: String,
        in db: Database
    ) throws -> [MeetingSyncTimed<Speaker>] {
        try SpeakerRecord
            .filter(Column("meetingID") == meetingKey)
            .filter(Column("deletedAt") == nil)
            .order(Column("createdAt"), Column("id"))
            .fetchAll(db)
            .map { record in
                var speaker = try record.speaker
                speaker.personID = nil
                return MeetingSyncTimed(
                    value: speaker,
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt)
            }
    }

    private static func meetingSyncSegments(
        meetingKey: String,
        in db: Database
    ) throws -> [MeetingSyncTimed<TranscriptSegment>] {
        try SegmentRecord
            .filter(Column("meetingID") == meetingKey)
            .filter(Column("deletedAt") == nil)
            .order(Column("startTime"), Column("id"))
            .fetchAll(db)
            .map { record in
                MeetingSyncTimed(
                    value: try record.segment,
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt)
            }
    }

    static func meetingSyncSummaries(
        meetingID: MeetingID,
        meetingKey: String,
        in db: Database
    ) throws -> [MeetingSyncSummary] {
        try SummaryRecord
            .filter(Column("meetingID") == meetingKey)
            .filter(Column("deletedAt") == nil)
            .order(Column("createdAt"), Column("id"))
            .fetchAll(db)
            .map { record in
                let snapshot = try summarySnapshot(record, meetingID: meetingID, in: db)
                let items = try ActionItemRecord
                    .filter(Column("summaryID") == record.id)
                    .filter(Column("deletedAt") == nil)
                    .order(Column("createdAt"), Column("id"))
                    .fetchAll(db)
                    .map { item in
                        MeetingSyncTimed(
                            value: try item.actionItem,
                            createdAt: item.createdAt,
                            updatedAt: item.updatedAt)
                    }
                return MeetingSyncSummary(
                    id: try PersistedIdentity.required(
                        record.id,
                        table: SummaryRecord.databaseTableName,
                        column: "id"),
                    meetingID: meetingID,
                    recipeID: record.recipeID,
                    language: record.language,
                    markdown: record.markdown,
                    version: snapshot.version,
                    fingerprint: record.fingerprint,
                    createdAt: record.createdAt,
                    actionItems: items,
                    claims: snapshot.draft.claims,
                    decisionEvidence: snapshot.draft.decisionEvidence,
                    actionItemEvidence: snapshot.draft.actionItemEvidence)
            }
    }

    private static func meetingSyncContextItems(
        meetingKey: String,
        in db: Database
    ) throws -> [MeetingSyncTimed<ContextItem>] {
        try ContextItemRecord
            .filter(Column("meetingID") == meetingKey)
            .filter(Column("deletedAt") == nil)
            .order(Column("timestamp"), Column("id"))
            .fetchAll(db)
            .map { record in
                MeetingSyncTimed(
                    value: try record.item,
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt)
            }
    }

    private static func meetingSyncCompanionCards(
        meetingKey: String,
        in db: Database
    ) throws -> [MeetingSyncTimed<CompanionCard>] {
        try CompanionCardRecord
            .filter(Column("meetingID") == meetingKey)
            .filter(Column("deletedAt") == nil)
            .order(Column("askedAt"), Column("id"))
            .fetchAll(db)
            .map { record in
                let card = try record.card.withEvidence(
                    companionCardEvidence(
                        cardID: try PersistedIdentity.required(
                            record.id,
                            table: CompanionCardRecord.databaseTableName,
                            column: "id"),
                        in: db))
                return MeetingSyncTimed(
                    value: card,
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt)
            }
    }
}
