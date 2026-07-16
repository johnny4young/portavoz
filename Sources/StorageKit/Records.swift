import Foundation
import GRDB
import PortavozCore

// Internal row shapes. IDs are stored as UUID strings; the retention
// policy as JSON (an enum with associated values). Domain types stay
// database-agnostic — mapping lives here and nowhere else.

enum PersistedIdentity {
    static func required(
        _ value: String, table: String, column: String
    ) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw StorageError.invalidPersistedUUID(
                table: table, column: column, value: value)
        }
        return uuid
    }

    static func optional(
        _ value: String?, table: String, column: String
    ) throws -> UUID? {
        guard let value else { return nil }
        return try required(value, table: table, column: column)
    }
}

struct MeetingRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meeting"

    var id: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var language: String?
    var audioDirectory: String?
    var retention: String
    var visibility: String
    var lifecycleState: String
    var transcriptRevision: Int
    var lastProcessingError: String?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(_ meeting: Meeting, createdAt: Date, updatedAt: Date, deletedAt: Date? = nil) throws {
        self.id = meeting.id.rawValue.uuidString
        self.title = meeting.title
        self.startedAt = meeting.startedAt
        self.endedAt = meeting.endedAt
        self.language = meeting.language
        self.audioDirectory = meeting.audioDirectory
        self.retention = try Self.encode(meeting.retention)
        self.visibility = meeting.visibility
        self.lifecycleState = meeting.lifecycleState.rawValue
        self.transcriptRevision = meeting.transcriptRevision
        self.lastProcessingError = meeting.lastProcessingError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var meeting: Meeting {
        get throws {
            guard let lifecycleState = MeetingLifecycleState(rawValue: lifecycleState) else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "lifecycleState",
                    value: self.lifecycleState)
            }
            return Meeting(
                id: MeetingID(rawValue: try PersistedIdentity.required(
                    id, table: Self.databaseTableName, column: "id")),
                title: title,
                startedAt: startedAt,
                endedAt: endedAt,
                language: language,
                audioDirectory: audioDirectory,
                retention: try Self.decode(retention),
                visibility: visibility,
                lifecycleState: lifecycleState,
                transcriptRevision: transcriptRevision,
                lastProcessingError: lastProcessingError
            )
        }
    }

    static func encode(_ policy: AudioRetentionPolicy) throws -> String {
        // JSONEncoder always emits valid UTF-8: the total conversion (never
        // nil) is intentional; the failable variant would change the contract.
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: try JSONEncoder().encode(policy), as: UTF8.self)
    }

    static func decode(_ text: String) throws -> AudioRetentionPolicy {
        try JSONDecoder().decode(AudioRetentionPolicy.self, from: Data(text.utf8))
    }
}

struct AudioAssetRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "audioAsset"

    var id: String
    var meetingID: String
    var channel: String
    var role: String
    var relativePath: String
    var container: String?
    var codec: String?
    var sampleRate: Double?
    var channelCount: Int?
    var durationSeconds: Double?
    var byteCount: Int64?
    var sha256: String?
    var healthStatus: String
    var peakDBFS: Double?
    var rmsDBFS: Double?
    var sourceAssetID: String?
    var createdAt: Date
    var updatedAt: Date
    var supersededAt: Date?
    var deletedAt: Date?

    init(_ asset: AudioAsset) {
        id = asset.id.rawValue.uuidString
        meetingID = asset.meetingID.rawValue.uuidString
        channel = asset.channel.rawValue
        role = asset.role.rawValue
        relativePath = asset.relativePath
        container = asset.container
        codec = asset.codec
        sampleRate = asset.sampleRate
        channelCount = asset.channelCount
        durationSeconds = asset.durationSeconds
        byteCount = asset.byteCount
        sha256 = asset.sha256
        healthStatus = asset.healthStatus.rawValue
        peakDBFS = asset.peakDBFS
        rmsDBFS = asset.rmsDBFS
        sourceAssetID = asset.sourceAssetID?.rawValue.uuidString
        createdAt = asset.createdAt
        updatedAt = asset.updatedAt
        supersededAt = asset.supersededAt
        deletedAt = asset.deletedAt
    }

    var asset: AudioAsset {
        get throws {
            guard let channel = AudioChannel(rawValue: channel) else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName, column: "channel", value: self.channel)
            }
            guard let health = AudioAssetHealthStatus(rawValue: healthStatus) else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "healthStatus",
                    value: healthStatus)
            }
            try StoredAudioPath.validate(relativePath)
            return AudioAsset(
                id: AudioAssetID(rawValue: try PersistedIdentity.required(
                    id, table: Self.databaseTableName, column: "id")),
                meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                    meetingID, table: Self.databaseTableName, column: "meetingID")),
                channel: channel,
                role: AudioAssetRole(rawValue: role),
                relativePath: relativePath,
                container: container,
                codec: codec,
                sampleRate: sampleRate,
                channelCount: channelCount,
                durationSeconds: durationSeconds,
                byteCount: byteCount,
                sha256: sha256,
                healthStatus: health,
                peakDBFS: peakDBFS,
                rmsDBFS: rmsDBFS,
                sourceAssetID: try PersistedIdentity.optional(
                    sourceAssetID, table: Self.databaseTableName, column: "sourceAssetID"
                ).map { AudioAssetID(rawValue: $0) },
                createdAt: createdAt,
                updatedAt: updatedAt,
                supersededAt: supersededAt,
                deletedAt: deletedAt)
        }
    }
}

struct SpeakerRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "speaker"

    var id: String
    var meetingID: String
    var label: String
    var displayName: String?
    var isMe: Bool
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(_ speaker: Speaker, createdAt: Date, updatedAt: Date) {
        self.id = speaker.id.rawValue.uuidString
        self.meetingID = speaker.meetingID.rawValue.uuidString
        self.label = speaker.label
        self.displayName = speaker.displayName
        self.isMe = speaker.isMe
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = nil
    }

    var speaker: Speaker {
        get throws {
            Speaker(
                id: SpeakerID(rawValue: try PersistedIdentity.required(
                    id, table: Self.databaseTableName, column: "id")),
                meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                    meetingID, table: Self.databaseTableName, column: "meetingID")),
                label: label,
                displayName: displayName,
                isMe: isMe
            )
        }
    }
}

struct SegmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "segment"

    var id: String
    var meetingID: String
    var speakerID: String?
    var channel: String
    var text: String
    var language: String?
    var startTime: Double
    var endTime: Double
    var confidence: Double?
    var isFinal: Bool
    var generationRunID: String?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    /// Float32 LE, L2-normalized sentence embedding (v2, local RAG).
    var embedding: Data?

    init(
        _ segment: TranscriptSegment,
        generationRunID: GenerationRunID? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = segment.id.uuidString
        self.meetingID = segment.meetingID.rawValue.uuidString
        self.speakerID = segment.speakerID?.rawValue.uuidString
        self.channel = segment.channel.rawValue
        self.text = segment.text
        self.language = segment.language
        self.startTime = segment.startTime
        self.endTime = segment.endTime
        self.confidence = segment.confidence
        self.isFinal = segment.isFinal
        self.generationRunID = generationRunID?.rawValue.uuidString
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = nil
        self.embedding = nil
    }

    var segment: TranscriptSegment {
        get throws {
            guard let parsedChannel = AudioChannel(rawValue: channel) else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName, column: "channel", value: channel)
            }
            return TranscriptSegment(
                id: try PersistedIdentity.required(
                    id, table: Self.databaseTableName, column: "id"),
                meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                    meetingID, table: Self.databaseTableName, column: "meetingID")),
                speakerID: try PersistedIdentity.optional(
                    speakerID, table: Self.databaseTableName, column: "speakerID"
                ).map { SpeakerID(rawValue: $0) },
                channel: parsedChannel,
                text: text,
                language: language,
                startTime: startTime,
                endTime: endTime,
                confidence: confidence,
                isFinal: isFinal
            )
        }
    }
}

struct SummaryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "summary"

    var id: String
    var meetingID: String
    var recipeID: String
    var language: String
    var markdown: String
    var version: Int
    var fingerprint: String?
    var generationRunID: String?
    var createdAt: Date
    var deletedAt: Date?
}

struct GenerationRunRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "generationRun"

    var id: String
    var meetingID: String
    var kind: String
    var providerID: String
    var modelID: String
    var modelRevision: String?
    var inputFingerprint: String
    var configJSON: String
    var outputLanguage: String?
    var startedAt: Date
    var finishedAt: Date?
    var outcome: String?
    var metricsJSON: String?

    init(_ run: GenerationRun) {
        id = run.id.rawValue.uuidString
        meetingID = run.meetingID.rawValue.uuidString
        kind = run.kind.rawValue
        providerID = run.providerID
        modelID = run.modelID
        modelRevision = run.modelRevision
        inputFingerprint = run.inputFingerprint
        configJSON = run.configJSON
        outputLanguage = run.outputLanguage
        startedAt = run.startedAt
        finishedAt = run.finishedAt
        outcome = run.outcome?.rawValue
        metricsJSON = run.metricsJSON
    }

    var run: GenerationRun {
        get throws {
            guard let kind = GenerationRunKind(rawValue: kind) else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName, column: "kind", value: self.kind)
            }
            let parsedOutcome: GenerationRunOutcome?
            if let outcome {
                guard let value = GenerationRunOutcome(rawValue: outcome) else {
                    throw StorageError.invalidPersistedValue(
                        table: Self.databaseTableName, column: "outcome", value: outcome)
                }
                parsedOutcome = value
            } else {
                parsedOutcome = nil
            }
            return GenerationRun(
                id: GenerationRunID(rawValue: try PersistedIdentity.required(
                    id, table: Self.databaseTableName, column: "id")),
                meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                    meetingID, table: Self.databaseTableName, column: "meetingID")),
                kind: kind,
                providerID: providerID,
                modelID: modelID,
                modelRevision: modelRevision,
                inputFingerprint: inputFingerprint,
                configJSON: configJSON,
                outputLanguage: outputLanguage,
                startedAt: startedAt,
                finishedAt: finishedAt,
                outcome: parsedOutcome,
                metricsJSON: metricsJSON)
        }
    }
}

struct DataEgressEventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "dataEgressEvent"

    var id: String
    var meetingID: String
    var operation: String
    var destinationScope: String
    var destinationHost: String
    var dataClassification: String
    var consentSource: String
    var providerID: String
    var modelID: String?
    var attemptedAt: Date

    init(_ event: DataEgressEvent, meetingID: MeetingID) {
        id = event.id.rawValue.uuidString
        self.meetingID = meetingID.rawValue.uuidString
        operation = event.operation.rawValue
        destinationScope = event.destinationScope.rawValue
        destinationHost = event.destinationHost
        dataClassification = event.dataClassification.rawValue
        consentSource = event.consentSource.rawValue
        providerID = event.providerID
        modelID = event.modelID
        attemptedAt = event.attemptedAt
    }

    var event: DataEgressEvent {
        get throws {
            guard let operation = DataEgressOperation(rawValue: operation) else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName, column: "operation", value: self.operation)
            }
            guard let destinationScope = DataEgressDestinationScope(rawValue: destinationScope) else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "destinationScope",
                    value: self.destinationScope)
            }
            guard let dataClassification = DataEgressClassification(
                rawValue: dataClassification)
            else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "dataClassification",
                    value: self.dataClassification)
            }
            guard let consentSource = DataEgressConsentSource(rawValue: consentSource) else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName,
                    column: "consentSource",
                    value: self.consentSource)
            }
            return DataEgressEvent(
                id: DataEgressEventID(rawValue: try PersistedIdentity.required(
                    id, table: Self.databaseTableName, column: "id")),
                meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                    meetingID, table: Self.databaseTableName, column: "meetingID")),
                operation: operation,
                destinationScope: destinationScope,
                destinationHost: destinationHost,
                dataClassification: dataClassification,
                consentSource: consentSource,
                providerID: providerID,
                modelID: modelID,
                attemptedAt: attemptedAt)
        }
    }
}

struct ActionItemRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "actionItem"

    var id: String
    var summaryID: String
    var meetingID: String
    var text: String
    var ownerSpeakerID: String?
    var isDone: Bool
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    var actionItem: ActionItem {
        get throws {
            _ = try PersistedIdentity.required(
                summaryID, table: Self.databaseTableName, column: "summaryID")
            _ = try PersistedIdentity.required(
                meetingID, table: Self.databaseTableName, column: "meetingID")
            return ActionItem(
                id: try PersistedIdentity.required(
                    id, table: Self.databaseTableName, column: "id"),
                text: text,
                ownerSpeakerID: try PersistedIdentity.optional(
                    ownerSpeakerID, table: Self.databaseTableName, column: "ownerSpeakerID"
                ).map { SpeakerID(rawValue: $0) },
                isDone: isDone
            )
        }
    }
}

struct ContextItemRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "contextItem"

    var id: String
    var meetingID: String
    var kind: String
    var content: String
    var timestamp: Double
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(_ item: ContextItem, createdAt: Date, updatedAt: Date) {
        self.id = item.id.uuidString
        self.meetingID = item.meetingID.rawValue.uuidString
        self.kind = item.kind.rawValue
        self.content = item.content
        self.timestamp = item.timestamp
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = nil
    }

    var item: ContextItem {
        get throws {
            let uuid = try PersistedIdentity.required(
                id, table: Self.databaseTableName, column: "id")
            let meetingUUID = try PersistedIdentity.required(
                meetingID, table: Self.databaseTableName, column: "meetingID")
            let rawKind = kind
            guard let kind = ContextItem.Kind(rawValue: rawKind) else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName, column: "kind", value: rawKind)
            }
            return ContextItem(
                id: uuid, meetingID: MeetingID(rawValue: meetingUUID),
                kind: kind, content: content, timestamp: timestamp)
        }
    }
}

struct CompanionCardRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "companionCard"

    var id: String
    var meetingID: String
    var question: String
    var answer: String
    var kind: String
    var source: String
    var directed: Bool
    var askedAt: Double
    var generationRunID: String?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    // `CompanionCard` carries no meetingID (it's a transient UI card); the
    // owning meeting is stamped here at persistence time.
    init(
        _ card: CompanionCard,
        meetingID: MeetingID,
        generationRunID: GenerationRunID? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = card.id.uuidString
        self.meetingID = meetingID.rawValue.uuidString
        self.question = card.question
        self.answer = card.answer
        self.kind = card.kind.rawValue
        self.source = card.source
        self.directed = card.directed
        self.askedAt = card.askedAt
        self.generationRunID = generationRunID?.rawValue.uuidString
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = nil
    }

    var card: CompanionCard {
        get throws {
            let uuid = try PersistedIdentity.required(
                id, table: Self.databaseTableName, column: "id")
            _ = try PersistedIdentity.required(
                meetingID, table: Self.databaseTableName, column: "meetingID")
            let rawKind = kind
            guard let kind = CompanionCard.Kind(rawValue: rawKind) else {
                throw StorageError.invalidPersistedValue(
                    table: Self.databaseTableName, column: "kind", value: rawKind)
            }
            return CompanionCard(
                id: uuid, question: question, answer: answer, kind: kind,
                source: source, directed: directed, askedAt: askedAt)
        }
    }
}
