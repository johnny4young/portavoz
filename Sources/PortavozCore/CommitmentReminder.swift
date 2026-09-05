import Foundation

/// Current local delivery state for a user-confirmed commitment reminder.
/// This is independent from the commitment deadline: snoozing delivery never
/// rewrites `Commitment.dueAt`.
public enum CommitmentReminderStatus: String, Codable, CaseIterable, Sendable {
    case scheduled
    case presented
    case dismissed
    case cancelled
}

/// Immutable facts in one reminder-delivery timeline.
public enum CommitmentReminderEventKind: String, Codable, CaseIterable, Sendable {
    case schedule
    case present
    case snooze
    case dismiss
    case cancel
}

public struct CommitmentReminderState: Codable, Sendable, Equatable, Identifiable {
    public var id: CommitmentID { commitmentID }
    public let commitmentID: CommitmentID
    public let status: CommitmentReminderStatus
    public let latestEventID: CommitmentReminderEventID
    public let scheduledFor: Date?
    public let sourceDueAt: Date?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        commitmentID: CommitmentID,
        status: CommitmentReminderStatus,
        latestEventID: CommitmentReminderEventID,
        scheduledFor: Date?,
        sourceDueAt: Date?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.commitmentID = commitmentID
        self.status = status
        self.latestEventID = latestEventID
        self.scheduledFor = scheduledFor
        self.sourceDueAt = sourceDueAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CommitmentReminderEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: CommitmentReminderEventID
    public let commitmentID: CommitmentID
    public let previousEventID: CommitmentReminderEventID?
    public let kind: CommitmentReminderEventKind
    public let scheduledFor: Date?
    public let sourceDueAt: Date?
    public let occurredAt: Date

    public init(
        id: CommitmentReminderEventID = CommitmentReminderEventID(),
        commitmentID: CommitmentID,
        previousEventID: CommitmentReminderEventID?,
        kind: CommitmentReminderEventKind,
        scheduledFor: Date? = nil,
        sourceDueAt: Date? = nil,
        occurredAt: Date
    ) {
        self.id = id
        self.commitmentID = commitmentID
        self.previousEventID = previousEventID
        self.kind = kind
        self.scheduledFor = scheduledFor
        self.sourceDueAt = sourceDueAt
        self.occurredAt = occurredAt
    }
}

/// One bounded reconciliation root. Storage returns the authoritative
/// commitment beside its current local delivery projection so application
/// policy can converge an idempotent scheduler without per-row reads.
public struct CommitmentReminderReconciliationItem: Sendable, Equatable, Identifiable {
    public var id: CommitmentID { commitment.id }
    public let commitment: Commitment
    public let reminder: CommitmentReminderState?

    public init(
        commitment: Commitment,
        reminder: CommitmentReminderState?
    ) {
        self.commitment = commitment
        self.reminder = reminder
    }
}

public enum ReminderReconciliationQueryError: Error, Sendable, Equatable {
    case invalidLimit
}

public struct CommitmentReminderReconciliationQuery: Sendable, Equatable {
    public static let maximumItemCount = 256
    public let itemLimit: Int

    public init(itemLimit: Int = 256) throws {
        guard (1...Self.maximumItemCount).contains(itemLimit) else {
            throw ReminderReconciliationQueryError.invalidLimit
        }
        self.itemLimit = itemLimit
    }
}

public struct CommitmentReminderReconciliationPage: Sendable, Equatable {
    public let items: [CommitmentReminderReconciliationItem]
    public let totalCount: Int

    public init(
        items: [CommitmentReminderReconciliationItem],
        totalCount: Int
    ) {
        self.items = items
        self.totalCount = totalCount
    }
}

public enum CommitmentReminderTransition: Sendable, Equatable {
    case schedule(scheduledFor: Date, sourceDueAt: Date)
    case present
    case snooze(until: Date)
    case dismiss
    case cancel
}

public enum CommitmentReminderValidationError: Error, Equatable, Sendable {
    case invalidEvent(CommitmentReminderEventID)
    case invalidLifecycle(CommitmentReminderEventID)
}

/// Replays and validates the reminder projection without notification-center,
/// persistence, calendar, clock, or UI dependencies.
public enum CommitmentReminderPolicy {
    public static func event(
        id: CommitmentReminderEventID = CommitmentReminderEventID(),
        commitmentID: CommitmentID,
        previousState: CommitmentReminderState?,
        transition: CommitmentReminderTransition,
        occurredAt: Date
    ) throws -> CommitmentReminderEvent {
        let previousEventID = previousState?.latestEventID
        switch transition {
        case .schedule(let scheduledFor, let sourceDueAt):
            return CommitmentReminderEvent(
                id: id,
                commitmentID: commitmentID,
                previousEventID: previousEventID,
                kind: .schedule,
                scheduledFor: scheduledFor,
                sourceDueAt: sourceDueAt,
                occurredAt: occurredAt)
        case .present:
            return CommitmentReminderEvent(
                id: id,
                commitmentID: commitmentID,
                previousEventID: previousEventID,
                kind: .present,
                occurredAt: occurredAt)
        case .snooze(let until):
            guard let sourceDueAt = previousState?.sourceDueAt else {
                throw CommitmentReminderValidationError.invalidLifecycle(id)
            }
            return CommitmentReminderEvent(
                id: id,
                commitmentID: commitmentID,
                previousEventID: previousEventID,
                kind: .snooze,
                scheduledFor: until,
                sourceDueAt: sourceDueAt,
                occurredAt: occurredAt)
        case .dismiss:
            return CommitmentReminderEvent(
                id: id,
                commitmentID: commitmentID,
                previousEventID: previousEventID,
                kind: .dismiss,
                occurredAt: occurredAt)
        case .cancel:
            return CommitmentReminderEvent(
                id: id,
                commitmentID: commitmentID,
                previousEventID: previousEventID,
                kind: .cancel,
                occurredAt: occurredAt)
        }
    }

    public static func applying(
        _ event: CommitmentReminderEvent,
        to previousState: CommitmentReminderState?
    ) throws -> CommitmentReminderState {
        guard event.previousEventID == previousState?.latestEventID,
              event.commitmentID == (previousState?.commitmentID ?? event.commitmentID),
              previousState.map({ event.occurredAt >= $0.updatedAt }) ?? true,
              validPayload(event)
        else {
            throw CommitmentReminderValidationError.invalidEvent(event.id)
        }

        let next: (
            status: CommitmentReminderStatus,
            scheduledFor: Date?,
            sourceDueAt: Date?
        )
        switch (previousState?.status, event.kind) {
        case (nil, .schedule), (.dismissed, .schedule), (.cancelled, .schedule):
            next = (.scheduled, event.scheduledFor, event.sourceDueAt)
        case (.scheduled, .present):
            next = (
                .presented,
                previousState?.scheduledFor,
                previousState?.sourceDueAt)
        case (.presented, .snooze):
            guard event.sourceDueAt == previousState?.sourceDueAt else {
                throw CommitmentReminderValidationError.invalidEvent(event.id)
            }
            next = (.scheduled, event.scheduledFor, event.sourceDueAt)
        case (.presented, .dismiss):
            next = (.dismissed, nil, nil)
        case (.scheduled, .cancel), (.presented, .cancel):
            next = (.cancelled, nil, nil)
        default:
            throw CommitmentReminderValidationError.invalidLifecycle(event.id)
        }

        return CommitmentReminderState(
            commitmentID: event.commitmentID,
            status: next.status,
            latestEventID: event.id,
            scheduledFor: next.scheduledFor,
            sourceDueAt: next.sourceDueAt,
            createdAt: previousState?.createdAt ?? event.occurredAt,
            updatedAt: event.occurredAt)
    }

    public static func projectedState(
        commitmentID: CommitmentID,
        events: [CommitmentReminderEvent]
    ) throws -> CommitmentReminderState? {
        var state: CommitmentReminderState?
        var seen = Set<CommitmentReminderEventID>()
        for event in events {
            guard event.commitmentID == commitmentID,
                  seen.insert(event.id).inserted
            else {
                throw CommitmentReminderValidationError.invalidEvent(event.id)
            }
            state = try applying(event, to: state)
        }
        return state
    }

    private static func validPayload(_ event: CommitmentReminderEvent) -> Bool {
        switch event.kind {
        case .schedule, .snooze:
            guard let scheduledFor = event.scheduledFor,
                  event.sourceDueAt != nil
            else { return false }
            return scheduledFor > event.occurredAt
        case .present, .dismiss, .cancel:
            return event.scheduledFor == nil && event.sourceDueAt == nil
        }
    }
}
