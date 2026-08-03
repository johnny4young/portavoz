import Foundation
import GRDB
import PortavozCore

struct TopicRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "topic"

    var id: String
    var preferredLabel: String
    var mergedIntoTopicID: String?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        _ topic: Topic,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        id = topic.id.rawValue.uuidString
        preferredLabel = topic.preferredLabel
        mergedIntoTopicID = topic.mergedIntoTopicID?.rawValue.uuidString
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var topic: Topic {
        get throws {
            Topic(
                id: TopicID(rawValue: try PersistedIdentity.required(
                    id, table: Self.databaseTableName, column: "id")),
                preferredLabel: preferredLabel,
                mergedIntoTopicID: try PersistedIdentity.optional(
                    mergedIntoTopicID,
                    table: Self.databaseTableName,
                    column: "mergedIntoTopicID"
                ).map { TopicID(rawValue: $0) })
        }
    }
}

struct TopicAliasRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "topicAlias"

    var id: String
    var topicID: String
    var displayLabel: String
    var normalizedAlias: String
    var language: String?
    var source: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        _ alias: TopicAlias,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        id = alias.id.rawValue.uuidString
        topicID = alias.topicID.rawValue.uuidString
        displayLabel = alias.displayLabel
        normalizedAlias = alias.normalizedAlias
        language = alias.language
        source = alias.source.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var alias: TopicAlias {
        get throws {
            guard let source = TopicLinkProposalOrigin(rawValue: source) else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "source",
                    value: self.source)
            }
            return TopicAlias(
                id: TopicAliasID(rawValue: try PersistedIdentity.required(
                    id, table: Self.databaseTableName, column: "id")),
                topicID: TopicID(rawValue: try PersistedIdentity.required(
                    topicID, table: Self.databaseTableName, column: "topicID")),
                displayLabel: displayLabel,
                normalizedAlias: normalizedAlias,
                language: language,
                source: source)
        }
    }
}

struct TopicMeetingEvidenceRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "topicMeetingEvidence"

    var id: String
    var topicID: String
    var aliasID: String
    var meetingID: String
    var segmentID: String
    var sourceTranscriptRevision: Int
    var observedLabel: String
    var language: String?
    var origin: String
    var resolution: String
    var suggestedTopicID: String?
    var similarity: Double?
    var profileFingerprint: String?
    var confirmedAt: Date

    init(_ evidence: TopicMeetingEvidence) {
        id = evidence.id.rawValue.uuidString
        topicID = evidence.topicID.rawValue.uuidString
        aliasID = evidence.aliasID.rawValue.uuidString
        meetingID = evidence.meetingID.rawValue.uuidString
        segmentID = evidence.segmentID.uuidString
        sourceTranscriptRevision = evidence.sourceTranscriptRevision
        observedLabel = evidence.observedLabel
        language = evidence.language
        origin = evidence.origin.rawValue
        resolution = evidence.resolution.rawValue
        suggestedTopicID = evidence.suggestedTopicID?.rawValue.uuidString
        similarity = evidence.similarity
        profileFingerprint = evidence.profileFingerprint
        confirmedAt = evidence.confirmedAt
    }

    func evidence(
        availability: TopicEvidenceAvailability
    ) throws -> TopicMeetingEvidence {
        guard let origin = TopicLinkProposalOrigin(rawValue: origin) else {
            throw StorageError.invalidPersistedValue(
                table: Self.databaseTableName,
                column: "origin",
                value: self.origin)
        }
        guard let resolution = TopicLinkResolution(rawValue: resolution) else {
            throw StorageError.invalidPersistedValue(
                table: Self.databaseTableName,
                column: "resolution",
                value: self.resolution)
        }
        return TopicMeetingEvidence(
            id: TopicMeetingEvidenceID(rawValue: try PersistedIdentity.required(
                id, table: Self.databaseTableName, column: "id")),
            topicID: TopicID(rawValue: try PersistedIdentity.required(
                topicID, table: Self.databaseTableName, column: "topicID")),
            aliasID: TopicAliasID(rawValue: try PersistedIdentity.required(
                aliasID, table: Self.databaseTableName, column: "aliasID")),
            meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                meetingID, table: Self.databaseTableName, column: "meetingID")),
            segmentID: try PersistedIdentity.required(
                segmentID, table: Self.databaseTableName, column: "segmentID"),
            sourceTranscriptRevision: sourceTranscriptRevision,
            observedLabel: observedLabel,
            language: language,
            origin: origin,
            resolution: resolution,
            suggestedTopicID: try PersistedIdentity.optional(
                suggestedTopicID,
                table: Self.databaseTableName,
                column: "suggestedTopicID"
            ).map { TopicID(rawValue: $0) },
            similarity: similarity,
            profileFingerprint: profileFingerprint,
            confirmedAt: confirmedAt,
            availability: availability)
    }
}

struct TopicIdentityEventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "topicIdentityEvent"

    var id: String
    var kind: String
    var sourceTopicID: String
    var targetTopicID: String
    var occurredAt: Date

    init(_ event: TopicIdentityEvent) {
        id = event.id.rawValue.uuidString
        kind = event.kind.rawValue
        sourceTopicID = event.sourceTopicID.rawValue.uuidString
        targetTopicID = event.targetTopicID.rawValue.uuidString
        occurredAt = event.occurredAt
    }

    var event: TopicIdentityEvent {
        get throws {
            guard let kind = TopicIdentityEventKind(rawValue: kind) else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "kind",
                    value: self.kind)
            }
            return TopicIdentityEvent(
                id: TopicIdentityEventID(rawValue: try PersistedIdentity.required(
                    id, table: Self.databaseTableName, column: "id")),
                kind: kind,
                sourceTopicID: TopicID(rawValue: try PersistedIdentity.required(
                    sourceTopicID,
                    table: Self.databaseTableName,
                    column: "sourceTopicID")),
                targetTopicID: TopicID(rawValue: try PersistedIdentity.required(
                    targetTopicID,
                    table: Self.databaseTableName,
                    column: "targetTopicID")),
                occurredAt: occurredAt)
        }
    }
}
