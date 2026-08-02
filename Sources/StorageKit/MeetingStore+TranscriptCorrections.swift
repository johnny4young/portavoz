import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Atomically appends one immutable event and its ordered typed payload.
    /// Repeating the same event is idempotent; reusing its identity for other
    /// content fails closed.
    public func appendTranscriptCorrection(
        _ proposedEvent: TranscriptCorrectionEvent
    ) async throws -> TranscriptCorrectionEvent {
        guard let event = try await appendTranscriptCorrections([proposedEvent]).first else {
            throw StorageError.invalidTranscriptCorrection(
                "an appended event could not be reloaded")
        }
        return event
    }

    /// Atomically appends one user edit that may contain independent text and
    /// speaker correction events. The batch either publishes every event or
    /// leaves correction history untouched.
    public func appendTranscriptCorrections(
        _ proposedEvents: [TranscriptCorrectionEvent]
    ) async throws -> [TranscriptCorrectionEvent] {
        guard !proposedEvents.isEmpty else { return [] }
        guard Set(proposedEvents.map(\.id)).count == proposedEvents.count else {
            throw StorageError.invalidTranscriptCorrection(
                "one correction event appeared more than once in the append batch")
        }
        let events = try proposedEvents.map { proposedEvent in
            do {
                try TranscriptCorrectionPolicy.validatePortable(proposedEvent)
            } catch {
                throw StorageError.invalidTranscriptCorrection(
                    "portable event is invalid: \(error)")
            }
            let event = Self.canonicalCorrectionEvent(proposedEvent)
            guard TranscriptCorrectionPolicy.samePersistedInstant(
                event.createdAt,
                event.updatedAt),
                event.deletedAt == nil
            else {
                throw StorageError.invalidTranscriptCorrection(
                    "new events must begin as immutable live records")
            }
            return event
        }

        return try await database.write {
            try Self.appendCanonicalTranscriptCorrections(events, in: $0)
        }
    }

    /// Returns the complete immutable history, including tombstones. Readers
    /// must keep tombstones so a removed terminal event never reactivates its
    /// predecessor accidentally.
    public func transcriptCorrectionHistory(
        for meetingID: MeetingID
    ) async throws -> [TranscriptCorrectionEvent] {
        try await database.read { database in
            guard try MeetingRecord.exists(
                database,
                key: meetingID.rawValue.uuidString)
            else { throw StorageError.meetingNotFound(meetingID) }
            return try Self.fetchTranscriptCorrectionHistory(
                meetingID: meetingID,
                in: database)
        }
    }

    /// Transport-neutral portable history. CloudKit conflict selection remains
    /// outside this storage contract until its deterministic policy is adopted.
    public func transcriptCorrectionSyncEnvelope(
        for meetingID: MeetingID
    ) async throws -> TranscriptCorrectionSyncEnvelope {
        let events = try await transcriptCorrectionHistory(for: meetingID)
        return try TranscriptCorrectionSyncEnvelope(
            meetingID: meetingID,
            events: events)
    }

    /// Tombstones a malformed or privacy-removed event while preserving source
    /// and payload history. Product undo appends a restore event instead.
    public func tombstoneTranscriptCorrection(
        _ correctionID: UUID,
        meetingID: MeetingID,
        at proposedTimestamp: Date = Date()
    ) async throws -> TranscriptCorrectionEvent {
        guard proposedTimestamp.timeIntervalSinceReferenceDate.isFinite else {
            throw StorageError.invalidTranscriptCorrection(
                "tombstone timestamp is invalid")
        }
        let timestamp = Self.canonicalCorrectionDate(proposedTimestamp)
        return try await database.write { database in
            let previousProjection = try Self.transcriptCorrectionRevision(
                meetingID: meetingID,
                in: database)
            guard let existing = try Self.fetchTranscriptCorrection(
                id: correctionID,
                in: database),
                existing.meetingID == meetingID
            else {
                throw StorageError.invalidTranscriptCorrection(
                    "tombstone target does not belong to the meeting")
            }
            if existing.deletedAt != nil { return existing }
            guard timestamp >= existing.updatedAt else {
                throw StorageError.invalidTranscriptCorrection(
                    "tombstone predates the event")
            }
            try database.execute(
                sql: """
                    UPDATE transcriptCorrection
                    SET deletedAt = ?, updatedAt = ?
                    WHERE id = ? AND deletedAt IS NULL
                    """,
                arguments: [timestamp, timestamp, correctionID.uuidString])
            guard let tombstone = try Self.fetchTranscriptCorrection(
                id: correctionID,
                in: database) else {
                throw StorageError.invalidTranscriptCorrection(
                    "tombstoned event could not be reloaded")
            }
            let currentProjection = try Self.transcriptCorrectionRevision(
                meetingID: meetingID,
                in: database)
            try Self.invalidateAcceptedOnlyDerivedWork(
                meetingID: meetingID,
                previous: previousProjection,
                current: currentProjection,
                at: timestamp,
                in: database)
            return tombstone
        }
    }
}

private extension MeetingStore {
    static func appendCanonicalTranscriptCorrections(
        _ events: [TranscriptCorrectionEvent],
        in database: Database
    ) throws -> [TranscriptCorrectionEvent] {
        var histories: [MeetingID: [TranscriptCorrectionEvent]] = [:]
        var originalProjections: [MeetingID: TranscriptCorrectionRevision] = [:]
        var persistedEvents: [TranscriptCorrectionEvent] = []
        for event in events {
            try requireLiveCorrectionMeeting(event, in: database)
            if originalProjections[event.meetingID] == nil {
                originalProjections[event.meetingID] = try transcriptCorrectionRevision(
                    meetingID: event.meetingID,
                    in: database)
            }
            if let existing = try fetchTranscriptCorrection(id: event.id, in: database) {
                guard sameCorrectionForRetry(existing, event) else {
                    throw StorageError.invalidTranscriptCorrection(
                        "event identity was reused with different content")
                }
                persistedEvents.append(existing)
                continue
            }

            let history = try histories[event.meetingID]
                ?? fetchTranscriptCorrectionHistory(
                    meetingID: event.meetingID,
                    in: database)
            try validateCorrectionAppendPredecessor(event, history: history)
            do {
                try TranscriptCorrectionPolicy.validateHistory(
                    history + [event],
                    meetingID: event.meetingID)
            } catch {
                throw StorageError.invalidTranscriptCorrection(
                    "event does not extend the correction history: \(error)")
            }
            try validateCorrectionAgainstAcceptedTranscript(event, in: database)
            try insertTranscriptCorrection(event, in: database)
            guard let persisted = try fetchTranscriptCorrection(
                id: event.id,
                in: database)
            else {
                throw StorageError.invalidTranscriptCorrection(
                    "inserted event could not be reloaded")
            }
            histories[event.meetingID] = history + [persisted]
            persistedEvents.append(persisted)
        }
        for (meetingID, previousProjection) in originalProjections {
            let currentProjection = try transcriptCorrectionRevision(
                meetingID: meetingID,
                in: database)
            let timestamp = persistedEvents
                .filter { $0.meetingID == meetingID }
                .map(\.updatedAt)
                .max() ?? Date()
            try invalidateAcceptedOnlyDerivedWork(
                meetingID: meetingID,
                previous: previousProjection,
                current: currentProjection,
                at: timestamp,
                in: database)
        }
        return persistedEvents
    }
}

extension MeetingStore {
    static func fetchTranscriptCorrectionHistory(
        meetingID: MeetingID,
        in database: Database
    ) throws -> [TranscriptCorrectionEvent] {
        let records = try TranscriptCorrectionRecord
            .filter(Column("meetingID") == meetingID.rawValue.uuidString)
            .order(Column("createdAt"), Column("id"))
            .fetchAll(database)
        let events = try assembleTranscriptCorrections(records, in: database)
            .sorted(by: TranscriptCorrectionPolicy.precedes)
        do {
            try TranscriptCorrectionPolicy.validateHistory(
                events,
                meetingID: meetingID)
        } catch {
            throw StorageError.invalidTranscriptCorrection(
                "persisted history is invalid: \(error)")
        }
        return events
    }

    static func fetchTranscriptCorrection(
        id: UUID,
        in database: Database
    ) throws -> TranscriptCorrectionEvent? {
        guard let record = try TranscriptCorrectionRecord.fetchOne(
            database,
            key: id.uuidString) else { return nil }
        return try assembleTranscriptCorrections([record], in: database).first
    }

    static func insertTranscriptCorrection(
        _ event: TranscriptCorrectionEvent,
        in database: Database
    ) throws {
        try TranscriptCorrectionRecord(event).insert(database)
        for (ordinal, segmentID) in event.targetSegmentIDs.enumerated() {
            try TranscriptCorrectionTargetRecord(
                correctionID: event.id.uuidString,
                segmentID: segmentID.uuidString,
                ordinal: ordinal)
                .insert(database)
        }
        switch event.kind {
        case .replaceText(let text, let language):
            try correctionPayload(
                event.id,
                text: text,
                language: language,
                speakerID: nil)
                .insert(database)
        case .changeSpeaker(let speakerID):
            try correctionPayload(
                event.id,
                text: nil,
                language: nil,
                speakerID: speakerID)
                .insert(database)
        case .split(let parts):
            for (ordinal, part) in parts.enumerated() {
                try TranscriptCorrectionPartRecord(
                    id: part.id.uuidString,
                    correctionID: event.id.uuidString,
                    ordinal: ordinal,
                    text: part.text,
                    speakerID: part.speakerID?.rawValue.uuidString,
                    language: part.language,
                    startTime: part.startTime,
                    endTime: part.endTime)
                    .insert(database)
            }
        case .merge(let replacementText, let language):
            try correctionPayload(
                event.id,
                text: replacementText,
                language: language,
                speakerID: nil)
                .insert(database)
        case .suppress, .restore:
            break
        }
    }

    private static func correctionPayload(
        _ correctionID: UUID,
        text: String?,
        language: String?,
        speakerID: SpeakerID?
    ) -> TranscriptCorrectionPayloadRecord {
        TranscriptCorrectionPayloadRecord(
            correctionID: correctionID.uuidString,
            text: text,
            language: language,
            speakerID: speakerID?.rawValue.uuidString)
    }
}

private extension MeetingStore {
    static func validateCorrectionAppendPredecessor(
        _ event: TranscriptCorrectionEvent,
        history: [TranscriptCorrectionEvent]
    ) throws {
        guard let predecessorID = event.supersedesCorrectionID else { return }
        let supersededIDs = Set(history.compactMap(\.supersedesCorrectionID))
        guard let predecessor = history.first(where: { $0.id == predecessorID }),
              predecessor.deletedAt == nil,
              !supersededIDs.contains(predecessorID)
        else {
            throw StorageError.invalidTranscriptCorrection(
                "supersession must extend the current live terminal event")
        }
    }

    static func requireLiveCorrectionMeeting(
        _ event: TranscriptCorrectionEvent,
        in database: Database
    ) throws {
        guard let meeting = try MeetingRecord.fetchOne(
            database,
            key: event.meetingID.rawValue.uuidString),
            meeting.deletedAt == nil
        else { throw StorageError.meetingNotFound(event.meetingID) }
        guard meeting.transcriptRevision == event.baseTranscriptRevision else {
            throw StorageError.invalidTranscriptCorrection(
                "base transcript revision is stale")
        }
    }

    static func validateCorrectionAgainstAcceptedTranscript(
        _ event: TranscriptCorrectionEvent,
        in database: Database
    ) throws {
        let meetingKey = event.meetingID.rawValue.uuidString
        let acceptedRecords = try SegmentRecord
            .filter(Column("meetingID") == meetingKey)
            .filter(Column("deletedAt") == nil)
            .filter(Column("isFinal") == true)
            .order(Column("startTime"), Column("endTime"), Column("id"))
            .fetchAll(database)
        let acceptedByID = Dictionary(uniqueKeysWithValues:
            acceptedRecords.map { ($0.id, $0) })
        let targetKeys = event.targetSegmentIDs.map(\.uuidString)
        guard targetKeys.allSatisfy({ acceptedByID[$0] != nil }),
              acceptedByID[event.id.uuidString] == nil,
              try TranscriptCorrectionPartRecord.exists(
                  database,
                  key: event.id.uuidString) == false
        else {
            throw StorageError.invalidTranscriptCorrection(
                "targets or generated row identity are not current")
        }

        let targets = targetKeys.compactMap { acceptedByID[$0] }
        switch event.kind {
        case .replaceText:
            break
        case .changeSpeaker(let speakerID):
            try validateCorrectionSpeakers(
                speakerID.map { [$0] } ?? [],
                meetingID: event.meetingID,
                in: database)
        case .split(let parts):
            guard let source = targets.first,
                  splitParts(parts, partition: source),
                  !parts.contains(where: { acceptedByID[$0.id.uuidString] != nil })
            else { throw StorageError.invalidTranscriptCorrection("split is invalid") }
            let partKeys = parts.map { $0.id.uuidString }
            guard try TranscriptCorrectionRecord
                .filter(partKeys.contains(Column("id")))
                .fetchCount(database) == 0,
                try TranscriptCorrectionPartRecord
                    .filter(partKeys.contains(Column("id")))
                    .fetchCount(database) == 0
            else {
                throw StorageError.invalidTranscriptCorrection(
                    "split row identity already exists")
            }
            try validateCorrectionSpeakers(
                parts.compactMap(\.speakerID),
                meetingID: event.meetingID,
                in: database)
        case .merge:
            try validateCorrectionMerge(
                event,
                targets: targets,
                acceptedRecords: acceptedRecords)
        case .suppress, .restore:
            break
        }
    }

    static func validateCorrectionMerge(
        _ event: TranscriptCorrectionEvent,
        targets: [SegmentRecord],
        acceptedRecords: [SegmentRecord]
    ) throws {
        let indexByID = Dictionary(uniqueKeysWithValues:
            acceptedRecords.enumerated().map { ($0.element.id, $0.offset) })
        let indexes = event.targetSegmentIDs.compactMap {
            indexByID[$0.uuidString]
        }
        guard targets.count >= 2,
              indexes == indexes.sorted(),
              indexes == Array(indexes[0]...indexes[indexes.count - 1]),
              Set(targets.map(\.speakerID)).count == 1,
              Set(targets.map(\.channel)).count == 1,
              zip(targets, targets.dropFirst()).allSatisfy({ pair in
                  pair.0.endTime <= pair.1.startTime
              })
        else { throw StorageError.invalidTranscriptCorrection("merge is invalid") }
    }

    static func splitParts(
        _ parts: [TranscriptCorrectionPart],
        partition source: SegmentRecord
    ) -> Bool {
        guard parts.first?.startTime == source.startTime,
              parts.last?.endTime == source.endTime
        else { return false }
        return zip(parts, parts.dropFirst()).allSatisfy { pair in
            pair.0.endTime == pair.1.startTime
        }
    }

    static func validateCorrectionSpeakers(
        _ speakerIDs: [SpeakerID],
        meetingID: MeetingID,
        in database: Database
    ) throws {
        let uniqueIDs = Set(speakerIDs)
        guard !uniqueIDs.isEmpty else { return }
        let keys = uniqueIDs.map { $0.rawValue.uuidString }
        let records = try SpeakerRecord
            .filter(keys.contains(Column("id")))
            .filter(Column("meetingID") == meetingID.rawValue.uuidString)
            .filter(Column("deletedAt") == nil)
            .fetchAll(database)
        guard records.count == uniqueIDs.count else {
            throw StorageError.invalidTranscriptCorrection(
                "speaker attribution is not meeting-local")
        }
    }

    static func canonicalCorrectionEvent(
        _ event: TranscriptCorrectionEvent
    ) -> TranscriptCorrectionEvent {
        TranscriptCorrectionEvent(
            id: event.id,
            meetingID: event.meetingID,
            baseTranscriptRevision: event.baseTranscriptRevision,
            targetSegmentIDs: event.targetSegmentIDs,
            kind: event.kind,
            author: event.author,
            sourceDeviceID: event.sourceDeviceID,
            createdAt: canonicalCorrectionDate(event.createdAt),
            updatedAt: canonicalCorrectionDate(event.updatedAt),
            deletedAt: event.deletedAt.map(canonicalCorrectionDate),
            supersedesCorrectionID: event.supersedesCorrectionID)
    }

    static func canonicalCorrectionDate(_ date: Date) -> Date {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    static func sameCorrectionForRetry(
        _ lhs: TranscriptCorrectionEvent,
        _ rhs: TranscriptCorrectionEvent
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.meetingID == rhs.meetingID
            && lhs.baseTranscriptRevision == rhs.baseTranscriptRevision
            && lhs.targetSegmentIDs == rhs.targetSegmentIDs
            && lhs.kind == rhs.kind
            && lhs.author == rhs.author
            && lhs.sourceDeviceID == rhs.sourceDeviceID
            && TranscriptCorrectionPolicy.samePersistedInstant(lhs.createdAt, rhs.createdAt)
            && TranscriptCorrectionPolicy.samePersistedInstant(lhs.updatedAt, rhs.updatedAt)
            && sameOptionalCorrectionInstant(lhs.deletedAt, rhs.deletedAt)
            && lhs.supersedesCorrectionID == rhs.supersedesCorrectionID
    }

    static func sameOptionalCorrectionInstant(
        _ lhs: Date?,
        _ rhs: Date?
    ) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): true
        case (.some(let left), .some(let right)):
            TranscriptCorrectionPolicy.samePersistedInstant(left, right)
        default: false
        }
    }

    static func assembleTranscriptCorrections(
        _ records: [TranscriptCorrectionRecord],
        in database: Database
    ) throws -> [TranscriptCorrectionEvent] {
        guard !records.isEmpty else { return [] }
        let correctionIDs = records.map(\.id)
        let targets = try TranscriptCorrectionTargetRecord
            .filter(correctionIDs.contains(Column("correctionID")))
            .order(Column("correctionID"), Column("ordinal"))
            .fetchAll(database)
        let payloads = try TranscriptCorrectionPayloadRecord
            .filter(correctionIDs.contains(Column("correctionID")))
            .fetchAll(database)
        let parts = try TranscriptCorrectionPartRecord
            .filter(correctionIDs.contains(Column("correctionID")))
            .order(Column("correctionID"), Column("ordinal"))
            .fetchAll(database)
        let targetsByCorrection = Dictionary(grouping: targets, by: \.correctionID)
        let payloadByCorrection = Dictionary(
            uniqueKeysWithValues: payloads.map { ($0.correctionID, $0) })
        let partsByCorrection = Dictionary(grouping: parts, by: \.correctionID)

        return try records.map { record in
            let targetIDs = try correctionTargets(
                targetsByCorrection[record.id] ?? [],
                correctionID: record.id)
            let kind = try correctionKind(
                record,
                payload: payloadByCorrection[record.id],
                parts: partsByCorrection[record.id] ?? [])
            let event = try correctionEvent(
                record,
                targets: targetIDs,
                kind: kind)
            do {
                try TranscriptCorrectionPolicy.validatePortable(event)
            } catch {
                throw invalidPersistedCorrection(
                    record.id,
                    "portable event: \(error)")
            }
            return event
        }
    }

    static func correctionTargets(
        _ records: [TranscriptCorrectionTargetRecord],
        correctionID: String
    ) throws -> [UUID] {
        try requireContiguousOrdinals(records.map(\.ordinal), correctionID: correctionID)
        return try records.map { record in
            try PersistedIdentity.required(
                record.segmentID,
                table: TranscriptCorrectionTargetRecord.databaseTableName,
                column: "segmentID")
        }
    }

    static func correctionKind(
        _ record: TranscriptCorrectionRecord,
        payload: TranscriptCorrectionPayloadRecord?,
        parts: [TranscriptCorrectionPartRecord]
    ) throws -> TranscriptCorrectionKind {
        switch record.kind {
        case "replaceText":
            return try decodedReplaceCorrection(record, payload: payload, parts: parts)
        case "changeSpeaker":
            return try decodedSpeakerCorrection(record, payload: payload, parts: parts)
        case "split":
            return try decodedSplitCorrection(record, payload: payload, parts: parts)
        case "merge":
            return try decodedMergeCorrection(record, payload: payload, parts: parts)
        case "suppress":
            return try decodedPayloadFreeCorrection(
                record,
                payload: payload,
                parts: parts,
                kind: .suppress)
        case "restore":
            return try decodedPayloadFreeCorrection(
                record,
                payload: payload,
                parts: parts,
                kind: .restore)
        default:
            throw StorageError.invalidPersistedValue(
                table: TranscriptCorrectionRecord.databaseTableName,
                column: "kind",
                value: record.kind)
        }
    }

    static func decodedReplaceCorrection(
        _ record: TranscriptCorrectionRecord,
        payload: TranscriptCorrectionPayloadRecord?,
        parts: [TranscriptCorrectionPartRecord]
    ) throws -> TranscriptCorrectionKind {
        guard let payload,
              let text = payload.text,
              payload.speakerID == nil,
              parts.isEmpty
        else { throw invalidPersistedCorrection(record.id, "replace payload") }
        return .replaceText(text: text, language: payload.language)
    }

    static func decodedSpeakerCorrection(
        _ record: TranscriptCorrectionRecord,
        payload: TranscriptCorrectionPayloadRecord?,
        parts: [TranscriptCorrectionPartRecord]
    ) throws -> TranscriptCorrectionKind {
        guard let payload,
              payload.text == nil,
              payload.language == nil,
              parts.isEmpty
        else { throw invalidPersistedCorrection(record.id, "speaker payload") }
        let speakerID = try PersistedIdentity.optional(
            payload.speakerID,
            table: TranscriptCorrectionPayloadRecord.databaseTableName,
            column: "speakerID")
        return .changeSpeaker(speakerID.map { SpeakerID(rawValue: $0) })
    }

    static func decodedSplitCorrection(
        _ record: TranscriptCorrectionRecord,
        payload: TranscriptCorrectionPayloadRecord?,
        parts: [TranscriptCorrectionPartRecord]
    ) throws -> TranscriptCorrectionKind {
        guard payload == nil, parts.count >= 2 else {
            throw invalidPersistedCorrection(record.id, "split payload")
        }
        try requireContiguousOrdinals(parts.map(\.ordinal), correctionID: record.id)
        return .split(try parts.map { try decodedSplitPart($0, correctionID: record.id) })
    }

    static func decodedSplitPart(
        _ part: TranscriptCorrectionPartRecord,
        correctionID: String
    ) throws -> TranscriptCorrectionPart {
        guard part.startTime.isFinite,
              part.endTime.isFinite,
              part.endTime > part.startTime
        else { throw invalidPersistedCorrection(correctionID, "split interval") }
        return TranscriptCorrectionPart(
            id: try PersistedIdentity.required(
                part.id,
                table: TranscriptCorrectionPartRecord.databaseTableName,
                column: "id"),
            text: part.text,
            speakerID: try PersistedIdentity.optional(
                part.speakerID,
                table: TranscriptCorrectionPartRecord.databaseTableName,
                column: "speakerID")
                .map { SpeakerID(rawValue: $0) },
            language: part.language,
            startTime: part.startTime,
            endTime: part.endTime)
    }

    static func decodedMergeCorrection(
        _ record: TranscriptCorrectionRecord,
        payload: TranscriptCorrectionPayloadRecord?,
        parts: [TranscriptCorrectionPartRecord]
    ) throws -> TranscriptCorrectionKind {
        guard let payload, payload.speakerID == nil, parts.isEmpty else {
            throw invalidPersistedCorrection(record.id, "merge payload")
        }
        return .merge(
            replacementText: payload.text,
            language: payload.language)
    }

    static func decodedPayloadFreeCorrection(
        _ record: TranscriptCorrectionRecord,
        payload: TranscriptCorrectionPayloadRecord?,
        parts: [TranscriptCorrectionPartRecord],
        kind: TranscriptCorrectionKind
    ) throws -> TranscriptCorrectionKind {
        guard payload == nil, parts.isEmpty else {
            throw invalidPersistedCorrection(record.id, "\(record.kind) payload")
        }
        return kind
    }

    static func correctionEvent(
        _ record: TranscriptCorrectionRecord,
        targets: [UUID],
        kind: TranscriptCorrectionKind
    ) throws -> TranscriptCorrectionEvent {
        guard let author = TranscriptCorrectionAuthor(rawValue: record.author) else {
            throw StorageError.invalidPersistedValue(
                table: TranscriptCorrectionRecord.databaseTableName,
                column: "author",
                value: record.author)
        }
        let sourceDeviceID = try PersistedIdentity.required(
            record.sourceDeviceID,
            table: TranscriptCorrectionRecord.databaseTableName,
            column: "sourceDeviceID")
        return TranscriptCorrectionEvent(
            id: try PersistedIdentity.required(
                record.id,
                table: TranscriptCorrectionRecord.databaseTableName,
                column: "id"),
            meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                record.meetingID,
                table: TranscriptCorrectionRecord.databaseTableName,
                column: "meetingID")),
            baseTranscriptRevision: record.baseTranscriptRevision,
            targetSegmentIDs: targets,
            kind: kind,
            author: author,
            sourceDeviceID: sourceDeviceID,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            deletedAt: record.deletedAt,
            supersedesCorrectionID: try PersistedIdentity.optional(
                record.supersedesCorrectionID,
                table: TranscriptCorrectionRecord.databaseTableName,
                column: "supersedesCorrectionID"))
    }

    static func requireContiguousOrdinals(
        _ ordinals: [Int],
        correctionID: String
    ) throws {
        guard ordinals == Array(0..<ordinals.count) else {
            throw invalidPersistedCorrection(correctionID, "noncontiguous ordinal")
        }
    }

    static func invalidPersistedCorrection(
        _: String,
        _ reason: String
    ) -> StorageError {
        StorageError.invalidTranscriptCorrection(
            "persisted event has invalid \(reason)")
    }
}
