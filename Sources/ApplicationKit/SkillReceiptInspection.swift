import Foundation
import PortavozCore
import StorageKit

public enum SkillControlCenterReceiptEventKind: Equatable, Sendable {
    case confirmed
    case started
    case succeeded
    case failed
    case cancelled
}

public struct SkillControlCenterReceiptEvent: Equatable, Sendable, Identifiable {
    /// Causal insertion position in the append-only event chain.
    public let sequence: Int
    public let kind: SkillControlCenterReceiptEventKind
    public let attempt: Int
    public let failureCategory: FailureCategory?
    public let occurredAt: Date

    public var id: Int { sequence }
}

public struct SkillControlCenterReceiptInspection: Equatable, Sendable {
    public let proposalID: UUID
    public let skillID: String
    public let skillVersion: Int
    public let state: SkillExecutionState
    public let failureCategory: FailureCategory?
    public let recoveryAvailability: SkillReceiptRecoveryAvailability
    public let attempt: Int
    public let updatedAt: Date
    public let events: [SkillControlCenterReceiptEvent]
}

public enum SkillReceiptInspectionError: Error, Equatable, Sendable {
    case unavailable
    case inconsistentHistory
}

/// Content-free guidance only. A review route never means that an effect can
/// run; the original subject surface must rebuild a fresh exact proposal and
/// own confirmation again.
public enum SkillReceiptRecoveryAvailability: Equatable, Sendable {
    case reviewInContext
    case residentMenuBar
    case verifyExternally
    case unavailable
}

public protocol SkillReceiptInspectionStore:
    SkillExecutionPolicyReading,
    Sendable {
    func skillExecutionAudit(
        proposalID: UUID
    ) async throws -> SkillExecutionAudit?
}

extension MeetingStore: SkillReceiptInspectionStore {}

/// Projects one content-free, read-consistent execution timeline for AUTO-6.
/// Storage owns causal order; this boundary rejects an impossible chain rather
/// than presenting plausible-looking audit evidence from corrupt state.
public struct LoadSkillReceiptInspection: ApplicationUseCase {
    private let store: any SkillReceiptInspectionStore

    public init(store: any SkillReceiptInspectionStore) {
        self.store = store
    }

    public func execute(
        _ proposalID: UUID
    ) async throws -> SkillControlCenterReceiptInspection {
        async let auditRead = store.skillExecutionAudit(proposalID: proposalID)
        async let policyRead = store.skillExecutionPolicy()
        guard let audit = try await auditRead
        else { throw SkillReceiptInspectionError.unavailable }
        let policy = try await policyRead
        guard audit.record.proposalID == proposalID else {
            throw SkillReceiptInspectionError.inconsistentHistory
        }
        let events = try Self.validateAndProject(audit)
        return SkillControlCenterReceiptInspection(
            proposalID: audit.record.proposalID,
            skillID: audit.record.skillID,
            skillVersion: audit.record.skillVersion,
            state: audit.record.state,
            failureCategory: audit.record.failureCategory,
            recoveryAvailability: Self.recoveryAvailability(
                audit: audit,
                policy: policy),
            attempt: audit.record.attempt,
            updatedAt: audit.record.updatedAt,
            events: events)
    }

    static func validateAndProject(
        _ audit: SkillExecutionAudit
    ) throws -> [SkillControlCenterReceiptEvent] {
        guard !audit.history.isEmpty else {
            throw SkillReceiptInspectionError.inconsistentHistory
        }
        var state: SkillExecutionState?
        var attempt = 1
        var events: [SkillControlCenterReceiptEvent] = []
        events.reserveCapacity(audit.history.count)

        for (offset, entry) in audit.history.enumerated() {
            let kind = try transition(
                entry,
                state: &state,
                currentAttempt: &attempt)
            events.append(SkillControlCenterReceiptEvent(
                sequence: offset + 1,
                kind: kind,
                attempt: entry.attempt,
                failureCategory: entry.failureCategory,
                occurredAt: entry.occurredAt))
        }

        let projectedFailureCategory = state == .failed
            ? events.last?.failureCategory
            : nil
        guard state == audit.record.state,
              attempt == audit.record.attempt,
              projectedFailureCategory == audit.record.failureCategory
        else { throw SkillReceiptInspectionError.inconsistentHistory }
        return events
    }

    static func recoveryAvailability(
        audit: SkillExecutionAudit,
        policy: SkillExecutionPolicy
    ) -> SkillReceiptRecoveryAvailability {
        guard audit.record.state == .failed,
              let failureCategory = audit.record.failureCategory
        else { return .unavailable }
        if failureCategory == .external || failureCategory == .destructive {
            return .verifyExternally
        }
        guard !policy.isPaused,
              policy.isIndividuallyEnabled(skillID: audit.record.skillID),
              let subject = audit.subject,
              subject.isValid,
              let catalogue = SkillCatalogue.entries.first(where: {
                  $0.id == audit.record.skillID
              }),
              catalogue.availability == .available,
              catalogue.definition.version == audit.record.skillVersion,
              catalogue.definition.subjectKind == subject.kind
        else { return .unavailable }
        return switch subject {
        case .meeting, .commitment: .reviewInContext
        case .calendarEvent: .residentMenuBar
        }
    }

    private static func transition(
        _ entry: SkillExecutionHistoryEntry,
        state: inout SkillExecutionState?,
        currentAttempt: inout Int
    ) throws -> SkillControlCenterReceiptEventKind {
        let kind: SkillControlCenterReceiptEventKind
        switch entry.kind {
        case "confirm":
            guard state == nil, entry.attempt == 1,
                  entry.failureCategory == nil
            else { throw SkillReceiptInspectionError.inconsistentHistory }
            state = .confirmed
            currentAttempt = 1
            kind = .confirmed
        case "begin":
            let isInitial = state == .confirmed && entry.attempt == currentAttempt
            let isRetry = state == .failed && entry.attempt == currentAttempt + 1
            guard isInitial || isRetry, entry.failureCategory == nil
            else { throw SkillReceiptInspectionError.inconsistentHistory }
            state = .executing
            currentAttempt = entry.attempt
            kind = .started
        case "succeed":
            guard state == .executing, entry.attempt == currentAttempt,
                  entry.failureCategory == nil
            else { throw SkillReceiptInspectionError.inconsistentHistory }
            state = .succeeded
            kind = .succeeded
        case "fail":
            guard state == .executing, entry.attempt == currentAttempt,
                  entry.failureCategory != nil
            else { throw SkillReceiptInspectionError.inconsistentHistory }
            state = .failed
            kind = .failed
        case "cancel":
            guard state == .confirmed, entry.attempt == currentAttempt,
                  entry.failureCategory == nil
            else { throw SkillReceiptInspectionError.inconsistentHistory }
            state = .dismissed
            kind = .cancelled
        default:
            throw SkillReceiptInspectionError.inconsistentHistory
        }
        return kind
    }
}

public enum SkillReceiptRecoveryNavigationOutcome: Equatable, Sendable {
    case destination(SkillOfferReviewDestination)
    case unavailable
}

/// Re-reads only content-free receipt authority and policy for one explicit
/// recovery request. It cannot reconstruct arguments, claim an execution, or
/// invoke an effect; it returns at most the original subject surface.
public struct ResolveSkillReceiptRecoveryDestination: ApplicationUseCase {
    private let store: any SkillReceiptInspectionStore

    public init(store: any SkillReceiptInspectionStore) {
        self.store = store
    }

    public func execute(
        _ proposalID: UUID
    ) async throws -> SkillReceiptRecoveryNavigationOutcome {
        try Task.checkCancellation()
        async let auditRead = store.skillExecutionAudit(proposalID: proposalID)
        async let policyRead = store.skillExecutionPolicy()
        guard let audit = try await auditRead,
              audit.record.proposalID == proposalID
        else { return .unavailable }
        let policy = try await policyRead
        _ = try LoadSkillReceiptInspection.validateAndProject(audit)
        guard LoadSkillReceiptInspection.recoveryAvailability(
            audit: audit,
            policy: policy) == .reviewInContext,
              let subject = audit.subject
        else { return .unavailable }
        return .destination(Self.destination(for: subject))
    }

    private static func destination(
        for subject: SkillSubject
    ) -> SkillOfferReviewDestination {
        switch subject {
        case .meeting(let id): .meeting(id)
        case .commitment(let id): .commitment(id)
        case .calendarEvent: .residentMenuBar
        }
    }
}
