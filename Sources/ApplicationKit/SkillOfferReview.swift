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
        reasonIsCompatible(record.reason, with: record.inputDataClasses)
        else { throw SkillOfferReviewError.invalidAuthority }
        return SkillOfferReviewItem(record: record)
    }

    private static func reasonIsCompatible(
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
