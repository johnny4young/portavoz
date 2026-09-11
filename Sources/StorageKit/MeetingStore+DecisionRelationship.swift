import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    static func applyDecisionRelationship(
        _ confirmation: DecisionRelationshipConfirmation,
        in database: Database
    ) throws -> DecisionContinuity {
        guard confirmation.confirmedAt.timeIntervalSinceReferenceDate.isFinite,
              confirmation.successorDecisionID != confirmation.targetDecisionID
        else {
            throw StorageError.invalidDecisionContinuity(
                "decision relationship is invalid")
        }
        if let existing = try DecisionContinuityEventRecord.fetchOne(
            database,
            key: confirmation.eventID.rawValue.uuidString) {
            return try replayDecisionRelationship(
                confirmation,
                existing: existing,
                in: database)
        }

        let target = try loadDecisionContinuity(
            confirmation.targetDecisionID,
            in: database)
        let successor = try loadDecisionContinuity(
            confirmation.successorDecisionID,
            in: database)
        guard target.decision.status == .confirmed,
              successor.decision.status == .confirmed
        else {
            throw StorageError.invalidDecisionContinuity(
                "both relationship decisions must still be confirmed")
        }
        let timestamp = decisionRelationshipTimestamp(
            confirmation.confirmedAt,
            targetEvents: target.events,
            successorCreatedAt: successor.decision.createdAt)
        let event = DecisionEvent(
            id: confirmation.eventID,
            decisionID: confirmation.targetDecisionID,
            kind: confirmation.kind.eventKind,
            relatedDecisionID: confirmation.successorDecisionID,
            occurredAt: timestamp)
        let projected: MeetingDecision
        do {
            projected = try DecisionContinuityPolicy.projectedDecision(
                id: target.decision.id,
                statement: target.decision.statement,
                events: target.events + [event])
        } catch let error as DecisionContinuityValidationError {
            throw StorageError.invalidDecisionContinuity(String(describing: error))
        }
        try DecisionContinuityEventRecord(event).insert(database)
        try DecisionContinuityRecord(projected).update(database)
        return try loadDecisionContinuity(confirmation.targetDecisionID, in: database)
    }

    static func replayDecisionRelationship(
        _ confirmation: DecisionRelationshipConfirmation,
        existing: DecisionContinuityEventRecord,
        in database: Database
    ) throws -> DecisionContinuity {
        let event = try existing.event
        guard event.decisionID == confirmation.targetDecisionID,
              event.kind == confirmation.kind.eventKind,
              event.sourceID == nil,
              event.relatedDecisionID == confirmation.successorDecisionID
        else {
            throw StorageError.invalidDecisionContinuity(
                "decision relationship identity was reused with different content")
        }
        let target = try loadDecisionContinuity(
            confirmation.targetDecisionID,
            in: database)
        let successor = try loadDecisionContinuity(
            confirmation.successorDecisionID,
            in: database)
        let predecessorEvents = target.events.filter { $0.id != confirmation.eventID }
        let expectedDate = decisionRelationshipTimestamp(
            confirmation.confirmedAt,
            targetEvents: predecessorEvents,
            successorCreatedAt: successor.decision.createdAt)
        guard sameDecisionDate(event.occurredAt, expectedDate) else {
            throw StorageError.invalidDecisionContinuity(
                "decision relationship identity was reused with a different timestamp")
        }
        return target
    }

    static func decisionRelationshipTimestamp(
        _ proposedDate: Date,
        targetEvents: [DecisionEvent],
        successorCreatedAt: Date
    ) -> Date {
        let requested = canonicalDecisionDate(proposedDate)
        let floor = max(
            targetEvents.map(\.occurredAt).max() ?? .distantPast,
            successorCreatedAt)
        return requested > floor
            ? requested
            : canonicalDecisionDate(floor.addingTimeInterval(0.001))
    }
}
