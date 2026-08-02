import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Creates continuity only after an explicit confirmation boundary. A
    /// generated origin must already be one evidence-linked durable ActionItem.
    public func confirmCommitment(
        _ confirmation: CommitmentConfirmation,
        at proposedDate: Date = Date()
    ) async throws -> CommitmentContinuityEnvelope {
        let timestamp = Self.canonicalCommitmentDate(proposedDate)
        return try await database.write { database in
            try Self.validateLivePerson(
                confirmation.assignee.canonicalPersonID,
                in: database)
            let source = try Self.confirmationSource(
                confirmation,
                at: timestamp,
                in: database)
            if let actionItemID = source.actionItemID,
               try Self.confirmedCommitment(
                   actionItemID: actionItemID,
                   in: database) != nil {
                throw StorageError.invalidCommitment(
                    "generated ActionItem is already confirmed")
            }
            let event = CommitmentEvent(
                id: confirmation.eventID,
                commitmentID: confirmation.commitmentID,
                kind: .confirm,
                assignee: confirmation.assignee,
                dueAt: confirmation.dueAt.map(Self.canonicalCommitmentDate),
                sourceMeetingID: source.meetingID,
                occurredAt: timestamp)
            let commitment = try CommitmentContinuityPolicy.projectedCommitment(
                id: confirmation.commitmentID,
                title: confirmation.title,
                events: [event])
            let envelope = try CommitmentContinuityEnvelope(
                commitment: commitment,
                sources: [source],
                events: [event])
            guard try CommitmentRecord.fetchOne(
                database,
                key: commitment.id.rawValue.uuidString) == nil
            else {
                throw StorageError.invalidCommitment(
                    "confirmed identity already exists")
            }
            try Self.insertCommitmentEnvelope(envelope, in: database)
            if let actionItemID = source.actionItemID {
                try Self.clearCommitmentReviewDecision(
                    actionItemID: actionItemID,
                    at: timestamp,
                    in: database)
            }
            return envelope
        }
    }

    /// Appends one user-confirmed, evidence-linked ActionItem to an existing
    /// open commitment. This never changes commitment identity or lifecycle;
    /// semantic/person candidates must cross the ApplicationKit confirmation
    /// boundary before this transaction can run.
    public func linkCommitmentSource(
        _ confirmation: CommitmentLinkConfirmation,
        at proposedDate: Date = Date()
    ) async throws -> CommitmentContinuityEnvelope {
        let requestedTimestamp = Self.canonicalCommitmentDate(proposedDate)
        return try await database.write { database in
            let current = try Self.commitmentEnvelope(
                id: confirmation.commitmentID,
                in: database)
            guard current.commitment.status == .confirmed else {
                throw StorageError.invalidCommitment(
                    "only an open commitment accepts new evidence")
            }
            try Self.validateActiveCommitmentSource(
                confirmation.actionItemID,
                meetingID: confirmation.sourceMeetingID,
                in: database)
            guard try Self.confirmedCommitment(
                actionItemID: confirmation.actionItemID,
                in: database) == nil
            else {
                throw StorageError.invalidCommitment(
                    "generated ActionItem is already confirmed")
            }
            let continuityFloor = max(
                current.commitment.updatedAt,
                current.sources.last?.firstSeenAt ?? current.commitment.updatedAt)
            let timestamp = requestedTimestamp > continuityFloor
                ? requestedTimestamp
                : continuityFloor.addingTimeInterval(0.001)
            let source = try Self.generatedActionItemSource(
                actionItemID: confirmation.actionItemID,
                commitmentID: confirmation.commitmentID,
                sourceID: confirmation.sourceID,
                at: timestamp,
                in: database)
            guard source.meetingID == confirmation.sourceMeetingID else {
                throw StorageError.invalidCommitment(
                    "generated ActionItem does not belong to the expected meeting")
            }
            guard !current.sources.contains(where: {
                $0.meetingID == confirmation.sourceMeetingID
            }) else {
                throw StorageError.invalidCommitment(
                    "cross-meeting evidence must come from a new meeting")
            }

            let envelope = try CommitmentContinuityEnvelope(
                commitment: current.commitment,
                sources: current.sources + [source],
                events: current.events)
            try CommitmentSourceRecord(source).insert(database)
            for evidence in source.evidence {
                try CommitmentEvidenceSegmentRecord(
                    sourceID: source.id,
                    evidence: evidence)
                    .insert(database)
            }
            try Self.clearCommitmentReviewDecision(
                actionItemID: confirmation.actionItemID,
                at: timestamp,
                in: database)
            return envelope
        }
    }

    /// Applies one strict append-only user-truth transition and updates the
    /// current projection in the same transaction.
    public func applyCommitmentTransition(
        _ transition: CommitmentTransition,
        to commitmentID: CommitmentID,
        eventID: CommitmentEventID = CommitmentEventID(),
        sourceMeetingID: MeetingID? = nil,
        at proposedDate: Date = Date()
    ) async throws -> CommitmentContinuityEnvelope {
        try await database.write { database in
            let current = try Self.commitmentEnvelope(
                id: commitmentID,
                in: database)
            try Self.validateLiveMeeting(sourceMeetingID, in: database)
            if case .reassign(let assignee) = transition {
                try Self.validateLivePerson(assignee.canonicalPersonID, in: database)
            }
            let lastDate = current.events.last?.occurredAt ?? current.commitment.updatedAt
            let requested = Self.canonicalCommitmentDate(proposedDate)
            let timestamp = requested > lastDate
                ? requested
                : lastDate.addingTimeInterval(0.001)
            let event = Self.commitmentEvent(
                id: eventID,
                commitmentID: commitmentID,
                transition: transition,
                sourceMeetingID: sourceMeetingID,
                occurredAt: timestamp)
            do {
                let events = current.events + [event]
                let commitment = try CommitmentContinuityPolicy.projectedCommitment(
                    id: commitmentID,
                    title: current.commitment.title,
                    events: events)
                let envelope = try CommitmentContinuityEnvelope(
                    commitment: commitment,
                    sources: current.sources,
                    events: events)
                try CommitmentEventRecord(event).insert(database)
                try CommitmentRecord(commitment).update(database)
                return envelope
            } catch let error as CommitmentContinuityValidationError {
                throw StorageError.invalidCommitment(String(describing: error))
            }
        }
    }

    public func commitmentContinuityEnvelope(
        for commitmentID: CommitmentID
    ) async throws -> CommitmentContinuityEnvelope {
        try await database.read { database in
            try Self.commitmentEnvelope(id: commitmentID, in: database)
        }
    }

    /// Imports one exact portable aggregate. Canonical owners are accepted by
    /// exact PersonID only; missing identities fail instead of alias matching.
    public func applyCommitmentContinuityEnvelope(
        _ proposedEnvelope: CommitmentContinuityEnvelope
    ) async throws -> CommitmentContinuityEnvelope {
        let envelope = try Self.canonicalCommitmentEnvelope(proposedEnvelope)
        return try await database.write { database in
            try Self.validateCommitmentReferences(envelope, in: database)
            let key = envelope.commitment.id.rawValue.uuidString
            if try CommitmentRecord.fetchOne(database, key: key) != nil {
                let local = try Self.commitmentEnvelope(
                    id: envelope.commitment.id,
                    in: database)
                guard local == envelope else {
                    throw StorageError.invalidCommitment(
                        "portable identity conflicts with local continuity")
                }
                return local
            }
            try Self.insertCommitmentEnvelope(envelope, in: database)
            let timestamp = Self.canonicalCommitmentDate(Date())
            for actionItemID in envelope.sources.compactMap(\.actionItemID) {
                try Self.clearCommitmentReviewDecision(
                    actionItemID: actionItemID,
                    at: timestamp,
                    in: database)
            }
            return envelope
        }
    }
}

private extension MeetingStore {
    static func confirmationSource(
        _ confirmation: CommitmentConfirmation,
        at timestamp: Date,
        in database: Database
    ) throws -> CommitmentSource {
        switch confirmation.origin {
        case .generatedActionItem(let actionItemID):
            return try generatedActionItemSource(
                actionItemID: actionItemID,
                commitmentID: confirmation.commitmentID,
                sourceID: confirmation.sourceID,
                at: timestamp,
                in: database)
        case .userNote(let contextItemID):
            guard let note = try ContextItemRecord.fetchOne(
                database,
                key: contextItemID.uuidString),
                  note.deletedAt == nil
            else { throw StorageError.invalidCommitment("user-note source is unavailable") }
            let meetingID = MeetingID(rawValue: try PersistedIdentity.required(
                note.meetingID,
                table: ContextItemRecord.databaseTableName,
                column: "meetingID"))
            try validateLiveMeeting(meetingID, in: database)
            return CommitmentSource(
                id: confirmation.sourceID,
                commitmentID: confirmation.commitmentID,
                kind: .userNote,
                meetingID: meetingID,
                contextItemID: contextItemID,
                firstSeenAt: timestamp)
        case .manual(let meetingID):
            try validateLiveMeeting(meetingID, in: database)
            return CommitmentSource(
                id: confirmation.sourceID,
                commitmentID: confirmation.commitmentID,
                kind: .manual,
                meetingID: meetingID,
                firstSeenAt: timestamp)
        }
    }

    static func generatedActionItemSource(
        actionItemID: UUID,
        commitmentID: CommitmentID,
        sourceID: CommitmentSourceID,
        at timestamp: Date,
        in database: Database
    ) throws -> CommitmentSource {
        guard let record = try ActionItemRecord.fetchOne(
            database,
            key: actionItemID.uuidString),
              record.deletedAt == nil,
              let summary = try SummaryRecord.fetchOne(
                database,
                key: record.summaryID),
              summary.deletedAt == nil,
              let meeting = try MeetingRecord.fetchOne(
                database,
                key: record.meetingID),
              meeting.deletedAt == nil
        else {
            throw StorageError.invalidCommitment(
                "generated ActionItem source is unavailable")
        }
        let actionItem = try record.actionItem
        guard let evidence = try summaryActionItemEvidence(
            actionItems: [actionItem],
            in: database).first,
              evidence.sourceTranscriptRevision == meeting.transcriptRevision,
              evidence.unavailableEvidenceCount == 0,
              !evidence.evidenceSegmentIDs.isEmpty
        else {
            throw StorageError.invalidCommitment(
                "generated ActionItem lacks current direct transcript evidence")
        }
        let segmentKeys = evidence.evidenceSegmentIDs.map(\.uuidString)
        let liveSegments = try SegmentRecord
            .filter(segmentKeys.contains(Column("id")))
            .filter(Column("meetingID") == record.meetingID)
            .filter(Column("deletedAt") == nil)
            .fetchCount(database)
        guard liveSegments == segmentKeys.count else {
            throw StorageError.invalidCommitment(
                "generated ActionItem evidence is stale or unavailable")
        }
        return CommitmentSource(
            id: sourceID,
            commitmentID: commitmentID,
            kind: .generatedActionItem,
            meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                record.meetingID,
                table: ActionItemRecord.databaseTableName,
                column: "meetingID")),
            actionItemID: actionItemID,
            transcriptRevision: evidence.sourceTranscriptRevision,
            firstSeenAt: timestamp,
            evidence: evidence.evidenceSegmentIDs.enumerated().map { ordinal, segmentID in
                CommitmentEvidenceSegment(
                    segmentID: segmentID,
                    role: .promise,
                    ordinal: ordinal)
            })
    }

    static func commitmentEvent(
        id: CommitmentEventID,
        commitmentID: CommitmentID,
        transition: CommitmentTransition,
        sourceMeetingID: MeetingID?,
        occurredAt: Date
    ) -> CommitmentEvent {
        switch transition {
        case .reassign(let assignee):
            return CommitmentEvent(
                id: id,
                commitmentID: commitmentID,
                kind: .reassign,
                assignee: assignee,
                sourceMeetingID: sourceMeetingID,
                occurredAt: occurredAt)
        case .reschedule(let dueAt):
            return CommitmentEvent(
                id: id,
                commitmentID: commitmentID,
                kind: .reschedule,
                dueAt: dueAt.map(canonicalCommitmentDate),
                sourceMeetingID: sourceMeetingID,
                occurredAt: occurredAt)
        case .complete:
            return CommitmentEvent(
                id: id,
                commitmentID: commitmentID,
                kind: .complete,
                sourceMeetingID: sourceMeetingID,
                occurredAt: occurredAt)
        case .reopen:
            return CommitmentEvent(
                id: id,
                commitmentID: commitmentID,
                kind: .reopen,
                sourceMeetingID: sourceMeetingID,
                occurredAt: occurredAt)
        case .dismiss:
            return CommitmentEvent(
                id: id,
                commitmentID: commitmentID,
                kind: .dismiss,
                sourceMeetingID: sourceMeetingID,
                occurredAt: occurredAt)
        }
    }

    static func commitmentEnvelope(
        id: CommitmentID,
        in database: Database
    ) throws -> CommitmentContinuityEnvelope {
        let key = id.rawValue.uuidString
        guard let record = try CommitmentRecord.fetchOne(database, key: key),
              record.deletedAt == nil
        else { throw StorageError.invalidCommitment("confirmed identity is unavailable") }
        let sourceRecords = try CommitmentSourceRecord
            .filter(Column("commitmentID") == key)
            .order(Column("firstSeenAt"), Column("id"))
            .fetchAll(database)
        let sources = try sourceRecords.map { sourceRecord in
            let evidence = try CommitmentEvidenceSegmentRecord
                .filter(Column("sourceID") == sourceRecord.id)
                .order(Column("ordinal"))
                .fetchAll(database)
                .map { try $0.evidence }
            return try sourceRecord.source(evidence: evidence)
        }
        let events = try CommitmentEventRecord
            .filter(Column("commitmentID") == key)
            .order(Column("occurredAt"), Column("id"))
            .fetchAll(database)
            .map { try $0.event }
        do {
            return try CommitmentContinuityEnvelope(
                commitment: record.commitment,
                sources: sources,
                events: events)
        } catch {
            throw StorageError.invalidCommitment(
                "persisted continuity failed validation: \(error)")
        }
    }

    static func insertCommitmentEnvelope(
        _ envelope: CommitmentContinuityEnvelope,
        in database: Database
    ) throws {
        do {
            try CommitmentRecord(envelope.commitment).insert(database)
            for source in envelope.sources {
                try CommitmentSourceRecord(source).insert(database)
                for evidence in source.evidence {
                    try CommitmentEvidenceSegmentRecord(
                        sourceID: source.id,
                        evidence: evidence)
                        .insert(database)
                }
            }
            for event in envelope.events {
                try CommitmentEventRecord(event).insert(database)
            }
        } catch let error as CommitmentContinuityValidationError {
            throw StorageError.invalidCommitment(String(describing: error))
        }
    }

    static func validateCommitmentReferences(
        _ envelope: CommitmentContinuityEnvelope,
        in database: Database
    ) throws {
        let personIDs = Set(
            [envelope.commitment.canonicalPersonID]
                + envelope.events.map(\.canonicalPersonID))
            .compactMap { $0 }
        for personID in personIDs {
            try validateLivePerson(personID, in: database)
        }
        for source in envelope.sources {
            switch source.kind {
            case .generatedActionItem:
                guard let actionItemID = source.actionItemID else {
                    throw StorageError.invalidCommitment("missing ActionItem source identity")
                }
                let material = try generatedActionItemSource(
                    actionItemID: actionItemID,
                    commitmentID: source.commitmentID,
                    sourceID: source.id,
                    at: source.firstSeenAt,
                    in: database)
                guard material.meetingID == source.meetingID,
                      material.transcriptRevision == source.transcriptRevision,
                      material.evidence == source.evidence
                else {
                    throw StorageError.invalidCommitment(
                        "portable ActionItem source does not match local evidence")
                }
            case .userNote:
                guard let contextItemID = source.contextItemID,
                      let record = try ContextItemRecord.fetchOne(
                        database,
                        key: contextItemID.uuidString),
                      record.deletedAt == nil,
                      source.meetingID?.rawValue.uuidString == record.meetingID
                else {
                    throw StorageError.invalidCommitment(
                        "portable user-note source does not match local evidence")
                }
            case .manual:
                try validateLiveMeeting(source.meetingID, in: database)
            }
        }
        for meetingID in envelope.events.compactMap(\.sourceMeetingID) {
            try validateLiveMeeting(meetingID, in: database)
        }
    }

    static func validateLivePerson(
        _ personID: PersonID?,
        in database: Database
    ) throws {
        guard let personID else { return }
        guard let person = try PersonRecord.fetchOne(
            database,
            key: personID.rawValue.uuidString),
              person.deletedAt == nil
        else {
            throw StorageError.invalidCommitment(
                "canonical owner must be an exact live PersonID")
        }
    }

    static func validateLiveMeeting(
        _ meetingID: MeetingID?,
        in database: Database
    ) throws {
        guard let meetingID else { return }
        guard let meeting = try MeetingRecord.fetchOne(
            database,
            key: meetingID.rawValue.uuidString),
              meeting.deletedAt == nil
        else { throw StorageError.invalidCommitment("source meeting is unavailable") }
    }

    static func canonicalCommitmentEnvelope(
        _ envelope: CommitmentContinuityEnvelope
    ) throws -> CommitmentContinuityEnvelope {
        let events = envelope.events.map { event in
            CommitmentEvent(
                id: event.id,
                commitmentID: event.commitmentID,
                kind: event.kind,
                assignee: event.assignee,
                dueAt: event.dueAt.map(canonicalCommitmentDate),
                sourceMeetingID: event.sourceMeetingID,
                occurredAt: canonicalCommitmentDate(event.occurredAt))
        }
        let commitment = try CommitmentContinuityPolicy.projectedCommitment(
            id: envelope.commitment.id,
            title: envelope.commitment.title,
            events: events)
        let sources = envelope.sources.map { source in
            CommitmentSource(
                id: source.id,
                commitmentID: source.commitmentID,
                kind: source.kind,
                meetingID: source.meetingID,
                actionItemID: source.actionItemID,
                contextItemID: source.contextItemID,
                transcriptRevision: source.transcriptRevision,
                firstSeenAt: canonicalCommitmentDate(source.firstSeenAt),
                evidence: source.evidence)
        }
        return try CommitmentContinuityEnvelope(
            commitment: commitment,
            sources: sources,
            events: events)
    }

}

extension MeetingStore {
    /// Commitment persistence uses millisecond precision across continuity and
    /// review feedback so transaction ordering is stable after a DB round trip.
    static func canonicalCommitmentDate(_ date: Date) -> Date {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}
