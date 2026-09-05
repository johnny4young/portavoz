import Foundation
import PortavozCore
import StorageKit

/// Content-free projection for the Skills pane. It deliberately excludes the
/// stable offer key and every subject identity, preview, destination, and
/// execution action.
public struct SkillOfferReviewItem: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let skillID: String
    public let skillVersion: Int
    public let reason: SkillOfferReason
    public let inputDataClasses: Set<SkillInputDataClass>
    public let proposedAt: Date
    public let lastObservedAt: Date

    init(record: SkillOfferReviewRecord) {
        id = record.id
        skillID = record.skillID
        skillVersion = record.skillVersion
        reason = record.reason
        inputDataClasses = record.inputDataClasses
        proposedAt = record.proposedAt
        lastObservedAt = record.lastObservedAt
    }
}

public struct SkillOfferReviewSnapshot: Equatable, Sendable {
    public static let defaultLimit = 20
    public static let maximumLimit = 50

    public let offers: [SkillOfferReviewItem]

    public init(offers: [SkillOfferReviewItem]) {
        self.offers = offers
    }
}

public protocol SkillOfferReviewStore: SkillExecutionPolicyReading, Sendable {
    func proposedSkillOffers(
        limit: Int,
        at now: Date
    ) async throws -> [SkillOfferReviewRecord]

    func dismissProposedSkillOffer(
        reviewID: UUID,
        at now: Date
    ) async throws -> SkillOfferReviewDismissalOutcome

    func resolveProposedSkillOfferSubject(
        reviewID: UUID,
        at now: Date
    ) async throws -> SkillOfferReviewSubjectOutcome
}

extension MeetingStore: SkillOfferReviewStore {}

public struct LoadSkillOfferReviewRequest: Equatable, Sendable {
    public let limit: Int

    public init(limit: Int = SkillOfferReviewSnapshot.defaultLimit) {
        self.limit = min(
            max(limit, 1),
            SkillOfferReviewSnapshot.maximumLimit)
    }
}

public enum SkillOfferReviewError: Error, Equatable, Sendable {
    case invalidAuthority
}

public struct LoadSkillOfferReview: ApplicationUseCase {
    private let store: any SkillOfferReviewStore
    private let now: @Sendable () -> Date

    public init(
        store: any SkillOfferReviewStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    public func execute(
        _ request: LoadSkillOfferReviewRequest
    ) async throws -> SkillOfferReviewSnapshot {
        let timestamp = now()
        async let policyRead = store.skillExecutionPolicy()
        async let offerRead = store.proposedSkillOffers(
            limit: request.limit,
            at: timestamp)
        let (policy, records) = try await (policyRead, offerRead)
        let validated = try records.map(Self.validate)
        guard !policy.isPaused else {
            return SkillOfferReviewSnapshot(offers: [])
        }
        return SkillOfferReviewSnapshot(offers: validated.filter {
            policy.isIndividuallyEnabled(skillID: $0.skillID)
        })
    }

    private static func validate(
        _ record: SkillOfferReviewRecord
    ) throws -> SkillOfferReviewItem {
        guard let catalogue = SkillCatalogue.entries.first(where: {
            $0.id == record.skillID
        }),
        catalogue.availability == .available,
        catalogue.definition.version == record.skillVersion,
        !record.inputDataClasses.isEmpty,
        record.inputDataClasses.isSubset(
            of: catalogue.definition.inputDataClasses),
        skillOfferReasonIsCompatible(
            record.reason,
            with: record.inputDataClasses)
        else { throw SkillOfferReviewError.invalidAuthority }
        return SkillOfferReviewItem(record: record)
    }
}

/// Dismisses one inert central review without receiving the stable offer key
/// or any subject identity. Exact preview and execution remain owned by the
/// original subject surface.
public struct DismissSkillOfferReview: ApplicationUseCase {
    private let store: any SkillOfferReviewStore
    private let now: @Sendable () -> Date

    public init(
        store: any SkillOfferReviewStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    public func execute(
        _ reviewID: UUID
    ) async throws -> SkillOfferReviewDismissalOutcome {
        try Task.checkCancellation()
        return try await store.dismissProposedSkillOffer(
            reviewID: reviewID,
            at: now())
    }
}

/// An inert original surface selected from one explicitly resolved opaque
/// review. Calendar offers deliberately expose only their resident surface,
/// not the opaque EventKit identity, because SwiftUI has no public action for
/// opening a MenuBarExtra programmatically.
public enum SkillOfferReviewDestination: Equatable, Sendable {
    case meeting(MeetingID)
    case commitment(CommitmentID)
    case residentMenuBar
}

public enum SkillOfferReviewNavigationOutcome: Equatable, Sendable {
    case destination(SkillOfferReviewDestination)
    case unavailable
}

/// Resolves only enough transient authority to return to the original review
/// surface. It cannot construct a proposal, confirm a preview, claim an
/// execution, choose a destination, or perform an effect.
public struct ResolveSkillOfferReviewDestination: ApplicationUseCase {
    private let store: any SkillOfferReviewStore
    private let now: @Sendable () -> Date

    public init(
        store: any SkillOfferReviewStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    public func execute(
        _ reviewID: UUID
    ) async throws -> SkillOfferReviewNavigationOutcome {
        try Task.checkCancellation()
        let timestamp = now()
        async let policyRead = store.skillExecutionPolicy()
        async let subjectRead = store.resolveProposedSkillOfferSubject(
            reviewID: reviewID,
            at: timestamp)
        let (policy, outcome) = try await (policyRead, subjectRead)
        guard !policy.isPaused else { return .unavailable }

        switch outcome {
        case .unavailable:
            return .unavailable
        case .active(let record):
            guard record.isValid,
                  let catalogue = SkillCatalogue.entries.first(where: {
                      $0.id == record.skillID
                  }),
                  catalogue.availability == .available,
                  catalogue.definition.version == record.skillVersion,
                  skillOfferReasonIsCompatible(
                      record.reason,
                      with: catalogue.definition.inputDataClasses)
            else { throw SkillOfferReviewError.invalidAuthority }
            guard policy.isIndividuallyEnabled(skillID: record.skillID) else {
                return .unavailable
            }
            return .destination(Self.destination(for: record.subject))
        }
    }

    private static func destination(
        for subject: SkillOfferSubject
    ) -> SkillOfferReviewDestination {
        switch subject {
        case .meeting(let id): .meeting(id)
        case .commitment(let id): .commitment(id)
        case .calendarEvent: .residentMenuBar
        }
    }
}

private func skillOfferReasonIsCompatible(
    _ reason: SkillOfferReason,
    with dataClasses: Set<SkillInputDataClass>
) -> Bool {
    switch reason {
    case .meetingSummaryReady:
        dataClasses.contains(.meetingSummary)
    case .upcomingCalendarEvent:
        dataClasses.contains(.calendarEvent)
    case .confirmedCommitment:
        dataClasses.contains(.commitment)
    }
}
