import Foundation
import PortavozCore
import StorageKit

public protocol StandingPreMeetingBriefExecutionStore: Sendable {
    func claimStandingSkillExecution(
        _ claim: StandingSkillExecutionClaim
    ) async throws -> StandingSkillExecutionAdmission
    func pendingStandingSkillExecutions(
        limit: Int
    ) async throws -> [PendingStandingSkillExecution]
    func completeStandingSkillExecution(
        proposalID: UUID,
        artifact: StandingSkillArtifact,
        at timestamp: Date
    ) async throws -> StandingSkillExecutionMutation
    func failStandingSkillExecution(
        proposalID: UUID,
        category: FailureCategory,
        at timestamp: Date
    ) async throws -> StandingSkillExecutionMutation
    func cancelSkillExecution(
        proposalID: UUID,
        at now: Date
    ) async throws -> SkillExecutionAdmission
    func standingSkillArtifact(
        proposalID: UUID
    ) async throws -> StandingSkillArtifact?
}

extension MeetingStore: StandingPreMeetingBriefExecutionStore {}

public protocol StandingPreMeetingBriefPreparing: Sendable {
    func prepareStandingPreMeetingBrief(
        for event: UpcomingEvent
    ) async throws -> MeetingBrief
}

extension PrepareMeetingBrief: StandingPreMeetingBriefPreparing {
    public func prepareStandingPreMeetingBrief(
        for event: UpcomingEvent
    ) async throws -> MeetingBrief {
        try await execute(event)
    }
}

public enum StandingPreMeetingBriefArtifactCodec {
    public static let maximumRelatedMeetingCount = 12
    public static let maximumOpenItemCount = 8
    public static let maximumKnowPointCount = 12
    public static let maximumAttendeeCount = 100
    public static let maximumMatchedTermCount = 32
    public static let maximumStringUTF8ByteCount = 16_000

    public static func encode(
        _ brief: MeetingBrief,
        at timestamp: Date
    ) throws -> StandingSkillArtifact {
        guard isValid(brief),
              timestamp.timeIntervalSinceReferenceDate.isFinite
        else { throw StandingPreMeetingBriefError.invalidArtifact }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(brief)
        let artifact = StandingSkillArtifact(
            kind: .preMeetingBrief,
            payload: data,
            createdAt: timestamp)
        guard artifact.isValid else {
            throw StandingPreMeetingBriefError.invalidArtifact
        }
        return artifact
    }

    public static func decode(
        _ artifact: StandingSkillArtifact
    ) throws -> MeetingBrief {
        guard artifact.isValid,
              artifact.kind == .preMeetingBrief,
              artifact.formatVersion
                == StandingSkillArtifact.currentFormatVersion
        else { throw StandingPreMeetingBriefError.invalidArtifact }
        let brief = try JSONDecoder().decode(
            MeetingBrief.self,
            from: artifact.payload)
        guard isValid(brief) else {
            throw StandingPreMeetingBriefError.invalidArtifact
        }
        return brief
    }

    private static func isValid(_ brief: MeetingBrief) -> Bool {
        guard brief.event.hasValidIdentity,
              brief.event.startDate.timeIntervalSinceReferenceDate.isFinite,
              brief.event.attendees.count <= maximumAttendeeCount,
              brief.related.count <= maximumRelatedMeetingCount,
              brief.openItems.count <= maximumOpenItemCount,
              brief.whatToKnow.count <= maximumKnowPointCount,
              isBounded(brief.event.title),
              brief.event.attendees.allSatisfy(isBounded),
              Set(brief.related.map(\.meetingID)).count == brief.related.count,
              Set(brief.openItems.map(\.id)).count == brief.openItems.count,
              Set(brief.whatToKnow.map(\.id)).count == brief.whatToKnow.count
        else { return false }
        let relatedIDs = Set(brief.related.map(\.meetingID))
        let relatedIsValid = brief.related.allSatisfy { meeting in
            meeting.matchedTerms.count <= maximumMatchedTermCount
                && isBounded(meeting.title)
                && isBounded(meeting.overview)
                && isBounded(meeting.snippet)
                && meeting.matchedTerms.allSatisfy(isBounded)
        }
        let openItemsAreValid = brief.openItems.allSatisfy { item in
            relatedIDs.contains(item.meetingID)
                && isBounded(item.meetingTitle)
                && isBounded(item.text)
        }
        let knowPointsAreValid = brief.whatToKnow.allSatisfy { point in
            relatedIDs.contains(point.meetingID)
                && isBounded(point.meetingTitle)
                && isBounded(point.text)
        }
        return relatedIsValid && openItemsAreValid && knowPointsAreValid
    }

    private static func isBounded(_ value: String) -> Bool {
        value.utf8.count <= maximumStringUTF8ByteCount
    }
}

public enum StandingPreMeetingBriefError: Error, Equatable, Sendable {
    case invalidRule
    case invalidEvent
    case invalidDailyWindow
    case invalidArtifact
    case eventChanged
    case timedOut
}

public enum StandingPreMeetingBriefOutcome: Equatable, Sendable {
    case prepared(UUID)
    case alreadyPrepared(UUID)
    case deferred(StandingSkillExecutionRefusal)
    case failed(UUID)
    case needsAttention(UUID)
}

/// One exact event execution. The claim and daily accounting commit before
/// preparation, while the contentful draft and successful receipt commit
/// atomically after exact-event revalidation.
public struct ExecuteStandingPreMeetingBrief: ApplicationUseCase {
    public static let maximumPreparationLeadTime: TimeInterval = 2 * 60 * 60

    private let store: any StandingPreMeetingBriefExecutionStore
    private let preparer: any StandingPreMeetingBriefPreparing
    private let events: any UpcomingEventResolving
    private let calendar: Calendar
    private let timeout: Duration
    private let cancelsClaimOnCancellation: Bool
    private let makeProposalID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    public init(
        store: any StandingPreMeetingBriefExecutionStore,
        preparer: any StandingPreMeetingBriefPreparing,
        events: any UpcomingEventResolving,
        calendar: Calendar = .autoupdatingCurrent,
        timeout: Duration = .seconds(30),
        cancelsClaimOnCancellation: Bool = true,
        makeProposalID: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.preparer = preparer
        self.events = events
        self.calendar = calendar
        self.timeout = timeout > .zero ? timeout : .seconds(30)
        self.cancelsClaimOnCancellation = cancelsClaimOnCancellation
        self.makeProposalID = makeProposalID
        self.now = now
    }

    public func execute(
        _ request: (rule: StandingSkillRule, event: UpcomingEvent)
    ) async throws -> StandingPreMeetingBriefOutcome {
        try Task.checkCancellation()
        guard StandingSkillRuleTemplate.prepareEveryUpcomingBrief.matches(
            request.rule),
              request.rule.isEnabled
        else { throw StandingPreMeetingBriefError.invalidRule }
        let claimedAt = now()
        guard Self.isEligible(request.event, at: claimedAt) else {
            throw StandingPreMeetingBriefError.invalidEvent
        }
        let claim = try makeClaim(
            rule: request.rule,
            event: request.event,
            claimedAt: claimedAt)
        switch try await store.claimStandingSkillExecution(claim) {
        case .refused(let refusal):
            return .deferred(refusal)
        case .duplicate(let record):
            return try await resume(
                record: record,
                event: request.event)
        case .admitted(let record):
            return try await prepare(
                record: record,
                event: request.event,
                cancelsOnCancellation: cancelsClaimOnCancellation)
        }
    }

    private func makeClaim(
        rule: StandingSkillRule,
        event: UpcomingEvent,
        claimedAt: Date
    ) throws -> StandingSkillExecutionClaim {
        guard let dailyWindow = Self.dailyWindow(
            containing: claimedAt,
            calendar: calendar)
        else { throw StandingPreMeetingBriefError.invalidDailyWindow }
        let occurrence = StandingSkillOccurrence(
            eventID: event.id,
            eventStartAt: event.startDate)
        let proposalID = makeProposalID()
        let proposal = SkillProposal(
            id: proposalID,
            definition: PreMeetingBriefSkill.standingRuleDefinition,
            subject: .calendarEvent(event.id),
            requestedCapabilities: [
                .readMeetingMaterial,
                .writeLocalDraft
            ],
            requestedInputDataClasses:
                PreMeetingBriefSkill.standingRuleDefinition.inputDataClasses,
            arguments: [.text(event.id)],
            proposedAt: claimedAt)
        guard case .admitted = SkillAdmissionPolicy.admit(
            proposal,
            isConfirmedByUser: false,
            egressIsPermitted: false,
            at: claimedAt)
        else { throw StandingPreMeetingBriefError.invalidRule }
        return StandingSkillExecutionClaim(
            proposalID: proposalID,
            ruleID: rule.id,
            skillID: rule.skillID,
            skillVersion: rule.skillVersion,
            trigger: rule.trigger,
            subjectPredicate: rule.subjectPredicate,
            action: rule.action,
            occurrence: occurrence,
            dailyWindow: dailyWindow,
            oneShotOfferKey: PreMeetingBriefSkill.idempotencyKey(
                forEvent: event.id),
            idempotencyKey: StandingSkillExecutionIdentity.idempotencyKey(
                ruleID: rule.id,
                occurrence: occurrence),
            occurredAt: claimedAt)
    }

    public func resume(
        _ pending: PendingStandingSkillExecution,
        event: UpcomingEvent
    ) async throws -> StandingPreMeetingBriefOutcome {
        guard pending.action == .preparePreMeetingBrief,
              pending.record.skillID == PreMeetingBriefSkill.id,
              pending.record.skillVersion == PreMeetingBriefSkill.version,
              pending.occurrence.matches(
                eventID: event.id,
                eventStartAt: event.startDate)
        else { throw StandingPreMeetingBriefError.eventChanged }
        return try await resume(record: pending.record, event: event)
    }

    private func resume(
        record: SkillExecutionRecord,
        event: UpcomingEvent
    ) async throws -> StandingPreMeetingBriefOutcome {
        switch record.state {
        case .succeeded:
            return .alreadyPrepared(record.proposalID)
        case .confirmed:
            return try await prepare(
                record: record,
                event: event,
                cancelsOnCancellation: cancelsClaimOnCancellation)
        case .failed:
            guard record.attempt
                    < StandingSkillExecutionPolicy.maximumAutomaticAttempts
            else { return .needsAttention(record.proposalID) }
            return try await prepare(
                record: record,
                event: event,
                cancelsOnCancellation: false)
        case .executing, .proposed, .previewed, .dismissed:
            return .needsAttention(record.proposalID)
        }
    }

    private func prepare(
        record: SkillExecutionRecord,
        event: UpcomingEvent,
        cancelsOnCancellation: Bool
    ) async throws -> StandingPreMeetingBriefOutcome {
        do {
            let brief = try await withStandingBriefTimeout(timeout) {
                try await preparer.prepareStandingPreMeetingBrief(for: event)
            }
            try Task.checkCancellation()
            guard Self.isSameEventSnapshot(brief.event, event),
                  let currentEvent = try await events.upcomingEvent(
                    matching: event.id),
                  Self.isSameEventSnapshot(currentEvent, event)
            else { throw StandingPreMeetingBriefError.eventChanged }
            let completedAt = now()
            let artifact = try StandingPreMeetingBriefArtifactCodec.encode(
                brief,
                at: completedAt)
            switch try await store.completeStandingSkillExecution(
                proposalID: record.proposalID,
                artifact: artifact,
                at: completedAt) {
            case .settled:
                return .prepared(record.proposalID)
            case .alreadySettled(let settled):
                return settled.state == .succeeded
                    ? .alreadyPrepared(record.proposalID)
                    : .needsAttention(record.proposalID)
            case .refused(let refusal):
                return .deferred(refusal)
            }
        } catch is CancellationError {
            if cancelsOnCancellation {
                await cancelConfirmedClaim(record.proposalID)
            }
            throw CancellationError()
        } catch let error as StandingPreMeetingBriefError
            where error == .eventChanged {
            await cancelConfirmedClaim(record.proposalID)
            throw error
        } catch {
            let failedAt = now()
            let outcome = try await store.failStandingSkillExecution(
                proposalID: record.proposalID,
                category: .recoverable,
                at: failedAt)
            return switch outcome {
            case .settled:
                .failed(record.proposalID)
            case .alreadySettled, .refused:
                .needsAttention(record.proposalID)
            }
        }
    }

    private func cancelConfirmedClaim(_ proposalID: UUID) async {
        let store = self.store
        let timestamp = now()
        _ = try? await Task {
            try await store.cancelSkillExecution(
                proposalID: proposalID,
                at: timestamp)
        }.value
    }

    public static func isEligible(
        _ event: UpcomingEvent,
        at timestamp: Date
    ) -> Bool {
        guard event.hasValidIdentity,
              event.startDate.timeIntervalSinceReferenceDate.isFinite,
              timestamp.timeIntervalSinceReferenceDate.isFinite
        else { return false }
        let lead = event.startDate.timeIntervalSince(timestamp)
        return lead >= 0 && lead <= maximumPreparationLeadTime
    }

    private static func isSameEventSnapshot(
        _ lhs: UpcomingEvent,
        _ rhs: UpcomingEvent
    ) -> Bool {
        let occurrence = StandingSkillOccurrence(
            eventID: lhs.id,
            eventStartAt: lhs.startDate)
        return occurrence.isValid
            && occurrence.matches(
                eventID: rhs.id,
                eventStartAt: rhs.startDate)
            && lhs.title == rhs.title
            && lhs.attendees == rhs.attendees
    }

    private static func dailyWindow(
        containing timestamp: Date,
        calendar: Calendar
    ) -> StandingSkillDailyWindow? {
        let start = calendar.startOfDay(for: timestamp)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start)
        else { return nil }
        let window = StandingSkillDailyWindow(
            startInclusive: start,
            endExclusive: end)
        return window.isValid ? window : nil
    }
}

private enum StandingBriefTimeoutResult<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
}

private func withStandingBriefTimeout<Value: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(
        of: StandingBriefTimeoutResult<Value>.self
    ) { group in
        group.addTask { .value(try await operation()) }
        group.addTask {
            try await Task.sleep(for: duration)
            return .timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw CancellationError()
        }
        switch first {
        case .value(let value):
            return value
        case .timedOut:
            throw StandingPreMeetingBriefError.timedOut
        }
    }
}
