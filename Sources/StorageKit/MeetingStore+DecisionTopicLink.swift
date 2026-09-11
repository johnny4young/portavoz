import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Creates the durable "decision is about topic" authority from one
    /// explicit confirmation over exact evidence. Idempotent: replaying the
    /// same identities returns the existing link, and reusing them with
    /// different content is refused.
    public func confirmDecisionTopicLink(
        _ confirmation: DecisionTopicLinkConfirmation
    ) async throws -> DecisionTopicLinkContinuity {
        try await database.write { database in
            try Self.confirmDecisionTopicLink(confirmation, in: database)
        }
    }

    /// Withdraws one confirmed link. Terminal: history keeps the retraction,
    /// and re-linking the pair creates a fresh link with fresh evidence.
    public func retractDecisionTopicLink(
        _ retraction: DecisionTopicLinkRetraction
    ) async throws -> DecisionTopicLinkContinuity {
        try await database.write { database in
            try Self.retractDecisionTopicLink(retraction, in: database)
        }
    }

    /// Active topic links of one decision, oldest confirmation first.
    public func decisionTopicLinks(
        for decisionID: DecisionID
    ) async throws -> [DecisionTopicLinkContinuity] {
        try await database.read { database in
            try DecisionTopicLinkRecord
                .filter(Column("decisionID") == decisionID.rawValue.uuidString)
                .filter(Column("status") == DecisionTopicLinkStatus.confirmed.rawValue)
                .filter(Column("deletedAt") == nil)
                .order(Column("createdAt"), Column("id"))
                .fetchAll(database)
                .map { try Self.loadDecisionTopicLinkContinuity($0, in: database) }
        }
    }

    /// Active decision links of one topic, oldest confirmation first. Answers
    /// for the exact topic identity given; family-root traversal belongs to
    /// the graph edge, not to the authority.
    public func decisionTopicLinks(
        for topicID: TopicID
    ) async throws -> [DecisionTopicLinkContinuity] {
        try await database.read { database in
            try DecisionTopicLinkRecord
                .filter(Column("topicID") == topicID.rawValue.uuidString)
                .filter(Column("status") == DecisionTopicLinkStatus.confirmed.rawValue)
                .filter(Column("deletedAt") == nil)
                .order(Column("createdAt"), Column("id"))
                .fetchAll(database)
                .map { try Self.loadDecisionTopicLinkContinuity($0, in: database) }
        }
    }
}

extension MeetingStore {
    static func confirmDecisionTopicLink(
        _ confirmation: DecisionTopicLinkConfirmation,
        in database: Database
    ) throws -> DecisionTopicLinkContinuity {
        guard confirmation.confirmedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw StorageError.invalidDecisionContinuity(
                "decision-topic link timestamp must be finite")
        }
        let linkKey = confirmation.linkID.rawValue.uuidString
        if let existing = try DecisionTopicLinkRecord.fetchOne(database, key: linkKey) {
            return try replayDecisionTopicLinkConfirmation(
                confirmation,
                existing: existing,
                in: database)
        }
        try validateUnusedDecisionTopicLinkConfirmationIdentities(
            confirmation,
            in: database)
        let context = try decisionTopicLinkConfirmationContext(
            confirmation,
            in: database)
        let write = try decisionTopicLinkConfirmationWrite(
            confirmation,
            context: context)
        return try write.insert(in: database)
    }

    private static func validateUnusedDecisionTopicLinkConfirmationIdentities(
        _ confirmation: DecisionTopicLinkConfirmation,
        in database: Database
    ) throws {
        guard try DecisionTopicLinkSourceRecord.fetchOne(
            database,
            key: confirmation.sourceID.rawValue.uuidString) == nil,
              try DecisionTopicLinkEventRecord.fetchOne(
                  database,
                  key: confirmation.eventID.rawValue.uuidString) == nil
        else {
            throw StorageError.invalidDecisionContinuity(
                "decision-topic link identities are already in use")
        }
    }

    private static func decisionTopicLinkConfirmationContext(
        _ confirmation: DecisionTopicLinkConfirmation,
        in database: Database
    ) throws -> DecisionTopicLinkConfirmationContext {
        // The observation must already be evidence the decision itself owns —
        // this is what keeps aboutness from being founded on co-occurrence.
        // The v32 trigger enforces the same condition below Swift.
        let observationKey = confirmation.observationID.rawValue.uuidString
        let decisionKey = confirmation.decisionID.rawValue.uuidString
        guard let owned = try DecisionContinuitySourceRecord
            .filter(Column("summaryDecisionID") == observationKey)
            .filter(Column("decisionID") == decisionKey)
            .fetchOne(database)
        else {
            throw StorageError.invalidDecisionContinuity(
                "decision-topic link evidence must already belong to the decision")
        }
        guard let decision = try DecisionContinuityRecord.fetchOne(
            database,
            key: decisionKey),
              decision.deletedAt == nil
        else {
            throw StorageError.invalidDecisionContinuity("decision is unavailable")
        }
        let topicKey = confirmation.topicID.rawValue.uuidString
        guard let topic = try TopicRecord.fetchOne(database, key: topicKey),
              topic.deletedAt == nil,
              topic.mergedIntoTopicID == nil
        else {
            throw StorageError.invalidDecisionContinuity(
                "decision-topic link target must be a live unmerged topic")
        }
        guard try DecisionTopicLinkRecord
            .filter(Column("decisionID") == decisionKey)
            .filter(Column("topicID") == topicKey)
            .filter(Column("status") == DecisionTopicLinkStatus.confirmed.rawValue)
            .filter(Column("deletedAt") == nil)
            .fetchCount(database) == 0
        else {
            throw StorageError.invalidDecisionContinuity(
                "decision-topic pair is already actively linked")
        }
        return DecisionTopicLinkConfirmationContext(
            ownedSource: owned,
            topic: topic)
    }

    private static func decisionTopicLinkConfirmationWrite(
        _ confirmation: DecisionTopicLinkConfirmation,
        context: DecisionTopicLinkConfirmationContext
    ) throws -> DecisionTopicLinkConfirmationWrite {
        let owned = context.ownedSource
        let timestamp = max(
            canonicalDecisionDate(confirmation.confirmedAt),
            canonicalDecisionDate(owned.observedAt))
        let link = DecisionTopicLink(
            id: confirmation.linkID,
            decisionID: confirmation.decisionID,
            topicID: confirmation.topicID,
            status: .confirmed,
            createdAt: timestamp,
            updatedAt: timestamp)
        guard let observationRaw = UUID(uuidString: owned.summaryDecisionID),
              let summaryRaw = UUID(uuidString: owned.summaryID),
              let meetingRaw = UUID(uuidString: owned.meetingID)
        else {
            throw StorageError.invalidDecisionContinuity(
                "decision evidence identity is malformed")
        }
        let source = DecisionTopicLinkSource(
            id: confirmation.sourceID,
            linkID: confirmation.linkID,
            observationID: SummaryDecisionID(rawValue: observationRaw),
            summaryID: SummaryID(rawValue: summaryRaw),
            meetingID: MeetingID(rawValue: meetingRaw),
            observedStatement: owned.observedStatement,
            observedTopicLabel: context.topic.preferredLabel,
            sourceTranscriptRevision: owned.sourceTranscriptRevision,
            observedAt: owned.observedAt,
            linkedAt: timestamp)
        let event = DecisionTopicLinkEvent(
            id: confirmation.eventID,
            linkID: confirmation.linkID,
            kind: .confirm,
            sourceID: confirmation.sourceID,
            occurredAt: timestamp)
        return DecisionTopicLinkConfirmationWrite(
            link: link,
            source: source,
            event: event)
    }

    static func retractDecisionTopicLink(
        _ retraction: DecisionTopicLinkRetraction,
        in database: Database
    ) throws -> DecisionTopicLinkContinuity {
        guard retraction.retractedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw StorageError.invalidDecisionContinuity(
                "decision-topic link timestamp must be finite")
        }
        let linkKey = retraction.linkID.rawValue.uuidString
        guard let record = try DecisionTopicLinkRecord.fetchOne(database, key: linkKey),
              record.deletedAt == nil
        else {
            throw StorageError.invalidDecisionContinuity(
                "decision-topic link is unavailable")
        }
        if let existing = try DecisionTopicLinkEventRecord.fetchOne(
            database,
            key: retraction.eventID.rawValue.uuidString) {
            let event = try existing.event
            guard event.linkID == retraction.linkID, event.kind == .retract else {
                throw StorageError.invalidDecisionContinuity(
                    "decision-topic link identities are already in use")
            }
            return try loadDecisionTopicLinkContinuity(record, in: database)
        }
        guard record.status == DecisionTopicLinkStatus.confirmed.rawValue else {
            throw StorageError.invalidDecisionContinuity(
                "only a confirmed decision-topic link can be retracted")
        }
        let timestamp = decisionTopicRetractionDate(
            retraction.retractedAt,
            after: record.updatedAt)
        let event = DecisionTopicLinkEvent(
            id: retraction.eventID,
            linkID: retraction.linkID,
            kind: .retract,
            sourceID: nil,
            occurredAt: timestamp)
        try DecisionTopicLinkEventRecord(event).insert(database)
        try database.execute(
            sql: """
                UPDATE decisionTopicLink
                SET status = 'retracted', updatedAt = ?
                WHERE id = ?
                """,
            arguments: [timestamp, linkKey])
        guard let updated = try DecisionTopicLinkRecord.fetchOne(
            database,
            key: linkKey)
        else {
            throw StorageError.invalidDecisionContinuity(
                "decision-topic link is unavailable")
        }
        return try loadDecisionTopicLinkContinuity(updated, in: database)
    }

    static func loadDecisionTopicLinkContinuity(
        _ record: DecisionTopicLinkRecord,
        in database: Database
    ) throws -> DecisionTopicLinkContinuity {
        guard let sourceRecord = try DecisionTopicLinkSourceRecord
            .filter(Column("linkID") == record.id)
            .fetchOne(database)
        else {
            throw StorageError.invalidDecisionContinuity(
                "decision-topic link has no source")
        }
        let events = try DecisionTopicLinkEventRecord
            .filter(Column("linkID") == record.id)
            .order(Column("occurredAt"), Column("id"))
            .fetchAll(database)
            .map { try $0.event }
        do {
            return try DecisionTopicLinkContinuity(
                link: try record.link,
                source: try sourceRecord.source,
                events: events)
        } catch let error as DecisionTopicLinkValidationError {
            throw StorageError.invalidDecisionContinuity(String(describing: error))
        }
    }

    private static func replayDecisionTopicLinkConfirmation(
        _ confirmation: DecisionTopicLinkConfirmation,
        existing: DecisionTopicLinkRecord,
        in database: Database
    ) throws -> DecisionTopicLinkContinuity {
        let continuity = try loadDecisionTopicLinkContinuity(existing, in: database)
        guard continuity.link.decisionID == confirmation.decisionID,
              continuity.link.topicID == confirmation.topicID,
              continuity.source.id == confirmation.sourceID,
              continuity.source.observationID == confirmation.observationID,
              continuity.events.first?.id == confirmation.eventID
        else {
            throw StorageError.invalidDecisionContinuity(
                "decision-topic link identity was reused with different content")
        }
        return continuity
    }

    /// Strictly after the link's last transition, mirroring the decision
    /// timestamp policy: a same-instant retraction would fail the transition
    /// trigger and a backward clock step must not make retraction impossible.
    private static func decisionTopicRetractionDate(
        _ proposed: Date,
        after floor: Date
    ) -> Date {
        let requested = canonicalDecisionDate(proposed)
        let bound = canonicalDecisionDate(floor)
        return requested > bound
            ? requested
            : canonicalDecisionDate(bound.addingTimeInterval(0.001))
    }
}

private struct DecisionTopicLinkConfirmationContext {
    let ownedSource: DecisionContinuitySourceRecord
    let topic: TopicRecord
}

private struct DecisionTopicLinkConfirmationWrite {
    let link: DecisionTopicLink
    let source: DecisionTopicLinkSource
    let event: DecisionTopicLinkEvent

    func insert(in database: Database) throws -> DecisionTopicLinkContinuity {
        try DecisionTopicLinkRecord(link).insert(database)
        try DecisionTopicLinkSourceRecord(source).insert(database)
        try DecisionTopicLinkEventRecord(event).insert(database)
        return try DecisionTopicLinkContinuity(
            link: link,
            source: source,
            events: [event])
    }
}
