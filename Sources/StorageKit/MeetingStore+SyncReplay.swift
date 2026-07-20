import Foundation
import GRDB
import PortavozCore

struct MeetingSyncLocalState {
    let audioDirectory: String?
    let peopleBySpeakerID: [String: String]
    let segmentsByID: [String: SegmentRecord]
    let summariesByID: [String: SummaryRecord]
    let portableSummariesByID: [String: MeetingSyncSummary]
    let cardsByID: [String: CompanionCardRecord]
}

extension MeetingStore {
    static func validateRemoteMeetingSyncAggregate(
        _ aggregate: MeetingSyncAggregate,
        meetingID: MeetingID
    ) throws {
        guard aggregate.formatVersion == MeetingSyncAggregate.currentFormatVersion,
              aggregate.meeting.value.id == meetingID,
              aggregate.meeting.value.audioDirectory == nil
        else {
            throw StorageError.invalidSyncState(
                "remote aggregate root or format is invalid")
        }

        let (speakerIDs, segmentIDs) = try validateRemoteCastAndTranscript(
            aggregate,
            meetingID: meetingID)
        try validateRemotePortableChildren(
            aggregate,
            meetingID: meetingID,
            speakerIDs: speakerIDs,
            segmentIDs: segmentIDs)
    }

    static func validateRemoteCastAndTranscript(
        _ aggregate: MeetingSyncAggregate,
        meetingID: MeetingID
    ) throws -> (Set<SpeakerID>, Set<UUID>) {
        let speakerIDs = Set(aggregate.speakers.map(\.value.id))
        let segmentIDs = Set(aggregate.segments.map(\.value.id))
        guard speakerIDs.count == aggregate.speakers.count,
              aggregate.speakers.allSatisfy({
                  $0.value.meetingID == meetingID && $0.value.personID == nil
              }),
              segmentIDs.count == aggregate.segments.count,
              aggregate.segments.allSatisfy({ segment in
                  segment.value.meetingID == meetingID
                      && (segment.value.speakerID.map(speakerIDs.contains) ?? true)
              })
        else {
            throw StorageError.invalidSyncState(
                "remote cast and transcript must be unique and meeting-local")
        }
        return (speakerIDs, segmentIDs)
    }

    static func validateRemotePortableChildren(
        _ aggregate: MeetingSyncAggregate,
        meetingID: MeetingID,
        speakerIDs: Set<SpeakerID>,
        segmentIDs: Set<UUID>
    ) throws {
        let summaryIDs = Set(aggregate.summaries.map(\.id))
        let summaryVersions = Set(aggregate.summaries.map {
            "\($0.recipeID)#\($0.version)"
        })
        let actionIDs = aggregate.summaries.flatMap { $0.actionItems.map(\.value.id) }
        guard summaryIDs.count == aggregate.summaries.count,
              summaryVersions.count == aggregate.summaries.count,
              Set(actionIDs).count == actionIDs.count,
              aggregate.summaries.allSatisfy({ summary in
                  summary.meetingID == meetingID
                      && summary.version > 0
                      && summary.actionItems.allSatisfy({ item in
                          item.value.ownerSpeakerID.map(speakerIDs.contains) ?? true
                      })
              }),
              Set(aggregate.contextItems.map(\.value.id)).count
                == aggregate.contextItems.count,
              aggregate.contextItems.allSatisfy({ $0.value.meetingID == meetingID }),
              Set(aggregate.companionCards.map(\.value.id)).count
                == aggregate.companionCards.count
        else {
            throw StorageError.invalidSyncState(
                "remote summaries, notes, or cards have invalid identities")
        }

        try validateRemoteSummaryEvidence(
            aggregate.summaries,
            segmentIDs: segmentIDs)
        try validateRemoteCompanionEvidence(
            aggregate.companionCards,
            segmentIDs: segmentIDs)
    }

    static func validateRemoteSummaryEvidence(
        _ summaries: [MeetingSyncSummary],
        segmentIDs: Set<UUID>
    ) throws {
        for summary in summaries {
            let localActions = Set(summary.actionItems.map(\.value.id))
            guard summary.actionItemEvidence.allSatisfy({ evidence in
                localActions.contains(evidence.actionItemID)
                    && evidence.unavailableEvidenceCount == 0
                    && !evidence.evidenceSegmentIDs.isEmpty
                    && evidence.evidenceSegmentIDs.allSatisfy(segmentIDs.contains)
            }),
            summary.claims.allSatisfy({ claim in
                claim.unavailableEvidenceCount == 0
                    && !claim.evidenceSegmentIDs.isEmpty
                    && claim.evidenceSegmentIDs.allSatisfy(segmentIDs.contains)
            }),
            summary.decisionEvidence.allSatisfy({ evidence in
                evidence.unavailableEvidenceCount == 0
                    && !evidence.evidenceSegmentIDs.isEmpty
                    && evidence.evidenceSegmentIDs.allSatisfy(segmentIDs.contains)
            }) else {
                throw StorageError.invalidSyncState(
                    "remote summary evidence is partial or foreign")
            }
        }
    }

    static func validateRemoteCompanionEvidence(
        _ cards: [MeetingSyncTimed<CompanionCard>],
        segmentIDs: Set<UUID>
    ) throws {
        for card in cards {
            guard let evidence = card.value.evidence else { continue }
            let links = evidence.questionSegmentIDs + evidence.answerSegmentIDs
            guard evidence.cardID == card.value.id,
                  evidence.unavailableQuestionCount == 0,
                  evidence.unavailableAnswerCount == 0,
                  !evidence.questionSegmentIDs.isEmpty,
                  links.allSatisfy(segmentIDs.contains)
            else {
                throw StorageError.invalidSyncState(
                    "remote Companion evidence is partial or foreign")
            }
        }
    }

    static func replaceWithRemoteMeetingSyncAggregate(
        _ aggregate: MeetingSyncAggregate,
        in db: Database
    ) throws {
        let meetingID = aggregate.meeting.value.id
        let key = meetingID.rawValue.uuidString
        let local = try meetingSyncLocalState(meetingID: meetingID, in: db)

        try validateImmutableRemoteSummaries(
            aggregate.summaries,
            against: local.portableSummariesByID)
        try deletePortableMeetingChildren(meetingKey: key, in: db)
        try insertRemoteMeeting(aggregate.meeting, local: local, in: db)
        try insertRemoteSpeakers(aggregate.speakers, local: local, in: db)
        try insertRemoteSegments(aggregate.segments, local: local, in: db)
        try insertRemoteSummaries(aggregate.summaries, local: local, in: db)
        try insertRemoteContextItems(aggregate.contextItems, in: db)
        try insertRemoteCompanionCards(
            aggregate.companionCards,
            meetingID: meetingID,
            local: local,
            in: db)
    }

    static func meetingSyncLocalState(
        meetingID: MeetingID,
        in db: Database
    ) throws -> MeetingSyncLocalState {
        let meetingKey = meetingID.rawValue.uuidString
        let people = try SpeakerRecord
            .filter(Column("meetingID") == meetingKey)
            .fetchAll(db)
            .compactMap { record in
                record.personID.map { (record.id, $0) }
            }
        return try MeetingSyncLocalState(
            audioDirectory: MeetingRecord.fetchOne(db, key: meetingKey)?.audioDirectory,
            peopleBySpeakerID: Dictionary(uniqueKeysWithValues: people),
            segmentsByID: dictionary(
                of: SegmentRecord.self,
                id: { $0.id },
                meetingKey: meetingKey,
                in: db),
            summariesByID: dictionary(
                of: SummaryRecord.self,
                id: { $0.id },
                meetingKey: meetingKey,
                in: db),
            portableSummariesByID: Dictionary(uniqueKeysWithValues:
                try meetingSyncSummaries(
                    meetingID: meetingID,
                    meetingKey: meetingKey,
                    in: db).map { ($0.id.uuidString, $0) }),
            cardsByID: dictionary(
                of: CompanionCardRecord.self,
                id: { $0.id },
                meetingKey: meetingKey,
                in: db))
    }

    static func dictionary<Record: FetchableRecord & TableRecord>(
        of type: Record.Type,
        id: (Record) -> String,
        meetingKey: String,
        in db: Database
    ) throws -> [String: Record] {
        let records = try type
            .filter(Column("meetingID") == meetingKey)
            .fetchAll(db)
        return Dictionary(uniqueKeysWithValues: records.map { (id($0), $0) })
    }

    static func deletePortableMeetingChildren(
        meetingKey: String,
        in db: Database
    ) throws {
        for table in [
            "actionItem", "summary", "contextItem", "companionCard", "segment", "speaker"
        ] {
            try db.execute(
                sql: "DELETE FROM \(table) WHERE meetingID = ?",
                arguments: [meetingKey])
        }
    }

    static func insertRemoteMeeting(
        _ synced: MeetingSyncTimed<Meeting>,
        local: MeetingSyncLocalState,
        in db: Database
    ) throws {
        var meeting = synced.value
        meeting.audioDirectory = local.audioDirectory
        try MeetingRecord(
            meeting,
            createdAt: synced.createdAt,
            updatedAt: synced.updatedAt,
            deletedAt: nil)
            .save(db)
    }

    static func insertRemoteSpeakers(
        _ speakers: [MeetingSyncTimed<Speaker>],
        local: MeetingSyncLocalState,
        in db: Database
    ) throws {
        for synced in speakers {
            var record = SpeakerRecord(
                synced.value,
                createdAt: synced.createdAt,
                updatedAt: synced.updatedAt)
            record.personID = local.peopleBySpeakerID[record.id]
            try record.insert(db)
        }
    }

    static func insertRemoteSegments(
        _ segments: [MeetingSyncTimed<TranscriptSegment>],
        local: MeetingSyncLocalState,
        in db: Database
    ) throws {
        for synced in segments {
            var record = SegmentRecord(
                synced.value,
                createdAt: synced.createdAt,
                updatedAt: synced.updatedAt)
            if let localRecord = local.segmentsByID[record.id],
               localRecord.text == record.text {
                record.embedding = localRecord.embedding
                record.generationRunID = localRecord.generationRunID
            }
            try record.insert(db)
        }
    }

    static func insertRemoteSummaries(
        _ summaries: [MeetingSyncSummary],
        local: MeetingSyncLocalState,
        in db: Database
    ) throws {
        for summary in summaries {
            try insertSyncedSummary(
                summary,
                generationRunID: local.summariesByID[summary.id.uuidString]?.generationRunID,
                in: db)
        }
    }

    static func insertRemoteContextItems(
        _ contextItems: [MeetingSyncTimed<ContextItem>],
        in db: Database
    ) throws {
        for synced in contextItems {
            try ContextItemRecord(
                synced.value,
                createdAt: synced.createdAt,
                updatedAt: synced.updatedAt)
                .insert(db)
        }
    }

    static func insertRemoteCompanionCards(
        _ cards: [MeetingSyncTimed<CompanionCard>],
        meetingID: MeetingID,
        local: MeetingSyncLocalState,
        in db: Database
    ) throws {
        for synced in cards {
            let localCard = local.cardsByID[synced.value.id.uuidString]
            let preservesGeneration = localCard.map {
                $0.question == synced.value.question
                    && $0.answer == synced.value.answer
                    && $0.kind == synced.value.kind.rawValue
                    && $0.source == synced.value.source
                    && $0.directed == synced.value.directed
                    && $0.askedAt == synced.value.askedAt
            } ?? false
            try CompanionCardRecord(
                synced.value,
                meetingID: meetingID,
                generationRunID: preservesGeneration
                    ? localCard?.generationRunID.flatMap(UUID.init(uuidString:)).map {
                        GenerationRunID(rawValue: $0)
                    }
                    : nil,
                createdAt: synced.createdAt,
                updatedAt: synced.updatedAt)
                .insert(db)
            try replaceCompanionCardEvidence(
                synced.value.evidence,
                cardID: synced.value.id,
                meetingID: meetingID,
                at: synced.updatedAt,
                in: db)
        }
    }

    static func validateImmutableRemoteSummaries(
        _ summaries: [MeetingSyncSummary],
        against local: [String: MeetingSyncSummary]
    ) throws {
        for summary in summaries {
            guard let existing = local[summary.id.uuidString] else { continue }
            if let difference = existing.immutableDifference(from: summary) {
                throw StorageError.invalidSyncState(
                    "remote sync cannot rewrite immutable summary \(difference)")
            }
        }
    }

    static func applyRemoteMeetingDeletion(
        meetingID: MeetingID,
        changedAt: Date,
        in db: Database
    ) throws {
        try db.execute(
            sql: "UPDATE meeting SET deletedAt = ?, updatedAt = ? WHERE id = ?",
            arguments: [changedAt, changedAt, meetingID.rawValue.uuidString])
    }

    static func settleRemoteMeetingMutation(
        meetingID: MeetingID,
        changedAt: Date,
        isDeleted: Bool,
        in db: Database
    ) throws {
        let key = meetingID.rawValue.uuidString
        if var state = try MeetingSyncStateRecord.fetchOne(db, key: key) {
            state.acknowledgedGeneration = state.localGeneration
            state.changedAt = changedAt
            state.isDeleted = isDeleted
            try state.update(db)
        } else {
            try MeetingSyncStateRecord(
                meetingID: key,
                localGeneration: 1,
                acknowledgedGeneration: 1,
                changedAt: changedAt,
                isDeleted: isDeleted)
                .insert(db)
        }
    }
}
