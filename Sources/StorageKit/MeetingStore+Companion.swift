import Foundation
import GRDB
import PortavozCore

// Companion snapshots and their model provenance. Kept beside the storage
// aggregate rather than inside the general MeetingStore surface.
extension MeetingStore {
    public func save(_ cards: [CompanionCard], for meetingID: MeetingID) async throws {
        try await database.write { db in
            let now = Date()
            for card in cards {
                let existing = try CompanionCardRecord.fetchOne(db, key: card.id.uuidString)
                var record = CompanionCardRecord(
                    card,
                    meetingID: meetingID,
                    createdAt: existing?.createdAt ?? now,
                    updatedAt: now)
                record.deletedAt = existing?.deletedAt
                record.generationRunID = existing?.generationRunID
                try record.save(db)
                try Self.replaceCompanionCardEvidence(
                    card.evidence,
                    cardID: card.id,
                    meetingID: meetingID,
                    at: now,
                    in: db)
            }
        }
    }

    public func companionCards(for id: MeetingID) async throws -> [CompanionCard] {
        try await database.read { db in
            try Self.fetchMeetingReviewCompanionCards(id, in: db)
        }
    }

    public func saveCompanionGenerationRun(
        _ run: GenerationRun,
        workflow: String,
        sourceTranscriptRevision: Int
    ) async throws {
        try Self.validateTerminalGenerationRun(run)
        guard run.kind == .companion,
              run.outcome != .succeeded,
              Self.companionConfigurationMatches(
                run,
                workflow: workflow,
                sourceTranscriptRevision: sourceTranscriptRevision)
        else {
            throw StorageError.invalidGenerationRun(
                "standalone Companion provenance must match its operation")
        }
        try await database.write { db in
            guard let meetingRecord = try MeetingRecord
                .filter(Column("id") == run.meetingID.rawValue.uuidString)
                .filter(Column("deletedAt") == nil)
                .fetchOne(db)
            else { throw StorageError.meetingNotFound(run.meetingID) }
            guard try meetingRecord.meeting.transcriptRevision == sourceTranscriptRevision else {
                throw StorageError.invalidGenerationRun(
                    "standalone Companion provenance is stale")
            }
            try GenerationRunRecord(run).insert(db)
        }
    }

    public func deleteCompanionCard(_ id: UUID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE companionCard SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [Date(), Date(), id.uuidString])
        }
    }

    /// Replaces a meeting's Companion cards wholesale. Refine re-runs the
    /// Companion over the accepted transcript, so replacement and provenance
    /// share one source-revision-fenced transaction.
    public func replaceCompanionCards(_ cards: [CompanionCard], for id: MeetingID) async throws {
        try await replaceCompanionCards(cards, generated: [], for: id)
    }

    public func replaceCompanionCards(
        _ cards: [CompanionCard],
        generated artifacts: [CompanionGenerationArtifact],
        for id: MeetingID
    ) async throws {
        let generatedIDs = Set(artifacts.map(\.card.id))
        guard Set(cards.map(\.id)).isDisjoint(with: generatedIDs) else {
            throw StorageError.invalidGenerationRun(
                "generated Companion cards cannot also be unlinked cards")
        }
        let key = id.rawValue.uuidString
        try await database.write { db in
            guard let meetingRecord = try MeetingRecord
                .filter(Column("id") == key)
                .filter(Column("deletedAt") == nil)
                .fetchOne(db)
            else { throw StorageError.meetingNotFound(id) }
            let meeting = try meetingRecord.meeting
            try Self.validateCompanionArtifacts(
                artifacts,
                meetingID: id,
                workflow: "post-refine",
                sourceTranscriptRevision: meeting.transcriptRevision)
            let now = Date()
            try Self.replaceCompanionCards(
                cards,
                generated: artifacts,
                meetingID: id,
                timestamp: now,
                in: db)
        }
    }

    static func validateCapturedCompanionProvenance(
        _ snapshot: CapturedMeetingSnapshot
    ) throws {
        let meeting = snapshot.meeting
        try validateCompanionArtifacts(
            snapshot.companionArtifacts,
            meetingID: meeting.id,
            workflow: "live-recording",
            sourceTranscriptRevision: meeting.transcriptRevision)
        let generatedCardIDs = Set(snapshot.companionArtifacts.map(\.card.id))
        let allRunIDs = snapshot.companionArtifacts.map(\.generationRun.id)
            + snapshot.companionTerminalRuns.map(\.id)
        guard Set(snapshot.companionCards.map(\.id)).isDisjoint(with: generatedCardIDs),
              Set(allRunIDs).count == allRunIDs.count
        else {
            throw StorageError.invalidGenerationRun(
                "captured Companion provenance must be unique")
        }
        for card in snapshot.companionCards {
            try validateCompanionEvidenceShape(
                card.evidence,
                cardID: card.id,
                sourceTranscriptRevision: meeting.transcriptRevision)
        }
        for run in snapshot.companionTerminalRuns {
            try validateTerminalGenerationRun(run)
            guard run.meetingID == meeting.id,
                  run.kind == .companion,
                  run.outcome != .succeeded,
                  companionConfigurationMatches(
                    run,
                    workflow: "live-recording",
                    sourceTranscriptRevision: meeting.transcriptRevision)
            else {
                throw StorageError.invalidGenerationRun(
                    "standalone Companion provenance must be terminal without an artifact")
            }
        }
    }

    static func validateCompanionArtifacts(
        _ artifacts: [CompanionGenerationArtifact],
        meetingID: MeetingID,
        workflow: String,
        sourceTranscriptRevision: Int
    ) throws {
        guard Set(artifacts.map(\.card.id)).count == artifacts.count,
              Set(artifacts.map(\.generationRun.id)).count == artifacts.count
        else { throw StorageError.invalidGenerationRun("Companion artifacts must be unique") }
        for artifact in artifacts {
            let run = artifact.generationRun
            try validateTerminalGenerationRun(run)
            try validateCompanionEvidenceShape(
                artifact.card.evidence,
                cardID: artifact.card.id,
                sourceTranscriptRevision: sourceTranscriptRevision)
            guard run.meetingID == meetingID,
                  run.kind == .companion,
                  run.outcome == .succeeded,
                  run.metricsJSON != nil,
                  companionConfigurationMatches(
                    run,
                    workflow: workflow,
                    sourceTranscriptRevision: sourceTranscriptRevision)
            else {
                throw StorageError.invalidGenerationRun(
                    "a Companion card requires matching succeeded current provenance")
            }
        }
    }

    static func companionConfigurationMatches(
        _ run: GenerationRun,
        workflow: String,
        sourceTranscriptRevision: Int
    ) -> Bool {
        guard let data = run.configJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let config = object as? [String: Any]
        else { return false }
        return config["workflow"] as? String == workflow
            && config["operation"] as? String == "classify-and-answer"
            && config["sourceTranscriptRevision"] as? Int == sourceTranscriptRevision
    }

    private static func replaceCompanionCards(
        _ cards: [CompanionCard],
        generated artifacts: [CompanionGenerationArtifact],
        meetingID: MeetingID,
        timestamp: Date,
        in db: Database
    ) throws {
        let key = meetingID.rawValue.uuidString
        try db.execute(
            sql: """
                UPDATE companionCard SET deletedAt = ?, updatedAt = ? \
                WHERE meetingID = ? AND deletedAt IS NULL
                """,
            arguments: [timestamp, timestamp, key])
        for card in cards {
            let record = CompanionCardRecord(
                card, meetingID: meetingID, createdAt: timestamp, updatedAt: timestamp)
            try record.save(db)
            try replaceCompanionCardEvidence(
                card.evidence,
                cardID: card.id,
                meetingID: meetingID,
                at: timestamp,
                in: db)
        }
        for artifact in artifacts {
            try GenerationRunRecord(artifact.generationRun).insert(db)
            let record = CompanionCardRecord(
                artifact.card,
                meetingID: meetingID,
                generationRunID: artifact.generationRun.id,
                createdAt: timestamp,
                updatedAt: timestamp)
            try record.save(db)
            try replaceCompanionCardEvidence(
                artifact.card.evidence,
                cardID: artifact.card.id,
                meetingID: meetingID,
                at: timestamp,
                in: db)
        }
    }
}
