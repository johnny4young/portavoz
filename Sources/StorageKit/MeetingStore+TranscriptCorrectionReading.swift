import Foundation
import GRDB
import PortavozCore

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
}

private extension MeetingStore {
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
