import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    static func confirmObservedDecision(
        _ confirmation: DecisionConfirmation,
        in database: Database
    ) throws -> DecisionContinuity {
        try validateDecisionDate(confirmation.confirmedAt)
        let decisionKey = confirmation.decisionID.rawValue.uuidString
        if try DecisionContinuityRecord.fetchOne(database, key: decisionKey) != nil {
            return try replayDecisionConfirmation(confirmation, in: database)
        }
        try requireAvailableDecisionConfirmationIdentities(
            sourceID: confirmation.sourceID,
            eventID: confirmation.eventID,
            observationID: confirmation.observationID,
            in: database)
        let observation = try decisionObservationForConfirmation(
            confirmation.observationID,
            in: database)
        let timestamp = max(
            canonicalDecisionDate(confirmation.confirmedAt),
            canonicalDecisionDate(observation.observedAt))
        let source = makeDecisionSource(
            id: confirmation.sourceID,
            decisionID: confirmation.decisionID,
            observation: observation,
            linkedAt: timestamp)
        let event = DecisionEvent(
            id: confirmation.eventID,
            decisionID: confirmation.decisionID,
            kind: .confirm,
            sourceID: confirmation.sourceID,
            occurredAt: timestamp)
        let decision: MeetingDecision
        do {
            decision = try DecisionContinuityPolicy.projectedDecision(
                id: confirmation.decisionID,
                statement: observation.statement,
                events: [event])
        } catch let error as DecisionContinuityValidationError {
            throw StorageError.invalidDecisionContinuity(String(describing: error))
        }
        try DecisionContinuityRecord(decision).insert(database)
        try insertDecisionSource(source, in: database)
        try DecisionContinuityEventRecord(event).insert(database)
        return try loadDecisionContinuity(confirmation.decisionID, in: database)
    }

    static func confirmAdditionalDecisionSource(
        _ confirmation: DecisionSourceConfirmation,
        in database: Database
    ) throws -> DecisionContinuity {
        try validateDecisionDate(confirmation.confirmedAt)
        let sourceKey = confirmation.sourceID.rawValue.uuidString
        if let existing = try DecisionContinuitySourceRecord.fetchOne(
            database,
            key: sourceKey) {
            return try replayDecisionSourceConfirmation(
                confirmation,
                existing: existing,
                in: database)
        }
        let current = try loadDecisionContinuity(confirmation.decisionID, in: database)
        guard current.decision.status == .confirmed else {
            throw StorageError.invalidDecisionContinuity(
                "only a current confirmed decision accepts later evidence")
        }
        try requireUnlinkedDecisionObservation(
            confirmation.observationID,
            in: database)
        let observation = try decisionObservationForConfirmation(
            confirmation.observationID,
            in: database)
        let timestamp = decisionSourceTimestamp(
            confirmation.confirmedAt,
            observedAt: observation.observedAt,
            confirmEventAt: current.events[0].occurredAt,
            priorSources: current.sources)
        let source = makeDecisionSource(
            id: confirmation.sourceID,
            decisionID: confirmation.decisionID,
            observation: observation,
            linkedAt: timestamp)
        try insertDecisionSource(source, in: database)
        return try loadDecisionContinuity(confirmation.decisionID, in: database)
    }

    static func replayDecisionConfirmation(
        _ confirmation: DecisionConfirmation,
        in database: Database
    ) throws -> DecisionContinuity {
        let continuity = try loadDecisionContinuity(confirmation.decisionID, in: database)
        guard let source = continuity.sources.first(where: {
            $0.id == confirmation.sourceID
        }),
              let event = continuity.events.first(where: {
                  $0.id == confirmation.eventID
              })
        else {
            throw StorageError.invalidDecisionContinuity(
                "decision confirmation identities are already in use")
        }
        let expectedDate = max(
            canonicalDecisionDate(confirmation.confirmedAt),
            canonicalDecisionDate(source.observedAt))
        guard source.observationID == confirmation.observationID,
              source.decisionID == confirmation.decisionID,
              sameDecisionDate(source.linkedAt, expectedDate),
              event.decisionID == confirmation.decisionID,
              event.kind == .confirm,
              event.sourceID == confirmation.sourceID,
              event.relatedDecisionID == nil,
              sameDecisionDate(event.occurredAt, expectedDate),
              continuity.decision.statement == source.observedStatement
        else {
            throw StorageError.invalidDecisionContinuity(
                "decision confirmation identity was reused with different content")
        }
        return continuity
    }

    static func replayDecisionSourceConfirmation(
        _ confirmation: DecisionSourceConfirmation,
        existing: DecisionContinuitySourceRecord,
        in database: Database
    ) throws -> DecisionContinuity {
        let evidence = try DecisionContinuityEvidenceSegmentRecord
            .filter(Column("sourceID") == existing.id)
            .order(Column("ordinal"))
            .fetchAll(database)
            .map { try $0.evidence }
        let source = try existing.source(
            evidence: evidence,
            availability: try decisionEvidenceAvailability(
                existing,
                evidence: evidence,
                in: database))
        let continuity = try loadDecisionContinuity(
            confirmation.decisionID,
            in: database)
        let expectedDate = decisionSourceTimestamp(
            confirmation.confirmedAt,
            observedAt: source.observedAt,
            confirmEventAt: continuity.events[0].occurredAt,
            priorSources: continuity.sources.filter {
                $0.id != source.id && $0.linkedAt < source.linkedAt
            })
        guard source.decisionID == confirmation.decisionID,
              source.observationID == confirmation.observationID,
              sameDecisionDate(source.linkedAt, expectedDate)
        else {
            throw StorageError.invalidDecisionContinuity(
                "decision source identity was reused with different content")
        }
        return continuity
    }

    static func requireAvailableDecisionConfirmationIdentities(
        sourceID: DecisionSourceID,
        eventID: DecisionEventID,
        observationID: SummaryDecisionID,
        in database: Database
    ) throws {
        guard try DecisionContinuitySourceRecord.fetchOne(
            database,
            key: sourceID.rawValue.uuidString) == nil,
              try DecisionContinuityEventRecord.fetchOne(
                  database,
                  key: eventID.rawValue.uuidString) == nil
        else {
            throw StorageError.invalidDecisionContinuity(
                "decision confirmation identities are already in use")
        }
        try requireUnlinkedDecisionObservation(observationID, in: database)
    }

    static func requireUnlinkedDecisionObservation(
        _ observationID: SummaryDecisionID,
        in database: Database
    ) throws {
        guard try DecisionContinuitySourceRecord
            .filter(Column("summaryDecisionID") == observationID.rawValue.uuidString)
            .fetchCount(database) == 0
        else {
            throw StorageError.invalidDecisionContinuity(
                "generated decision observation is already confirmed")
        }
    }

    static func makeDecisionSource(
        id: DecisionSourceID,
        decisionID: DecisionID,
        observation: DecisionObservation,
        linkedAt: Date
    ) -> DecisionSource {
        DecisionSource(
            id: id,
            decisionID: decisionID,
            observationID: observation.id,
            summaryID: observation.summaryID,
            meetingID: observation.meetingID,
            observedStatement: observation.statement,
            sourceTranscriptRevision: observation.sourceTranscriptRevision,
            observedAt: observation.observedAt,
            linkedAt: linkedAt,
            evidence: observation.evidence,
            availability: .current)
    }

    static func insertDecisionSource(
        _ source: DecisionSource,
        in database: Database
    ) throws {
        try DecisionContinuitySourceRecord(source).insert(database)
        for evidence in source.evidence {
            try DecisionContinuityEvidenceSegmentRecord(
                sourceID: source.id,
                evidence: evidence)
                .insert(database)
        }
    }

    private static func validateDecisionDate(_ date: Date) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw StorageError.invalidDecisionContinuity(
                "decision timestamp must be finite")
        }
    }

    static func decisionSourceTimestamp(
        _ proposedDate: Date,
        observedAt: Date,
        confirmEventAt: Date,
        priorSources: [DecisionSource]
    ) -> Date {
        let requested = canonicalDecisionDate(proposedDate)
        let floor = [
            canonicalDecisionDate(observedAt),
            canonicalDecisionDate(confirmEventAt),
            priorSources.map(\.linkedAt).max() ?? .distantPast
        ].max() ?? .distantPast
        return requested > floor
            ? requested
            : canonicalDecisionDate(floor.addingTimeInterval(0.001))
    }
}
