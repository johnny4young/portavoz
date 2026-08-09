import Foundation
import PortavozCore
import StorageKit

/// One event-scoped proposal rendered by the resident menu-bar surface.
/// Its key contains only the opaque calendar reference, never title or time.
public struct PreMeetingBriefOffer: Equatable, Sendable, Identifiable {
    public let event: UpcomingEvent
    public let offerKey: String

    public var id: String { offerKey }

    public init?(event: UpcomingEvent) {
        guard event.hasValidIdentity else { return nil }
        self.event = event
        offerKey = PreMeetingBriefSkill.idempotencyKey(forEvent: event.id)
    }
}

public protocol PreMeetingBriefOfferStore: SkillExecutionPolicyReading, Sendable {
    func dismissedSkillOffers(offerKeys: [String]) async throws -> Set<String>
    func skillExecution(idempotencyKey: String) async throws -> SkillExecutionRecord?
    func dismissSkillOffer(
        offerKey: String,
        skillID: String,
        at timestamp: Date
    ) async throws
}

extension MeetingStore: PreMeetingBriefOfferStore {}

/// Loads only actionable proposals. A failed execution remains retryable;
/// every other durable owner is fail-closed because it either settled or may
/// already have crossed the effect boundary.
public struct LoadPreMeetingBriefOffer: ApplicationUseCase {
    private let store: any PreMeetingBriefOfferStore

    public init(store: any PreMeetingBriefOfferStore) {
        self.store = store
    }

    public func execute(_ event: UpcomingEvent) async throws -> PreMeetingBriefOffer? {
        guard event.hasValidIdentity else { return nil }
        let policy = try await store.skillExecutionPolicy()
        guard policy.isEnabled(skillID: PreMeetingBriefSkill.id) else { return nil }
        guard let offer = PreMeetingBriefOffer(event: event) else { return nil }
        let dismissed = try await store.dismissedSkillOffers(offerKeys: [offer.offerKey])
        guard !dismissed.contains(offer.offerKey) else { return nil }
        guard let execution = try await store.skillExecution(
            idempotencyKey: offer.offerKey)
        else { return offer }
        return execution.state == .failed ? offer : nil
    }
}

public struct DismissPreMeetingBriefOffer: ApplicationUseCase {
    private let store: any PreMeetingBriefOfferStore
    private let now: @Sendable () -> Date

    public init(
        store: any PreMeetingBriefOfferStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    public func execute(_ offer: PreMeetingBriefOffer) async throws {
        guard offer.event.hasValidIdentity,
              offer.offerKey == PreMeetingBriefSkill.idempotencyKey(
                forEvent: offer.event.id)
        else { return }
        try await store.dismissSkillOffer(
            offerKey: offer.offerKey,
            skillID: PreMeetingBriefSkill.id,
            at: now())
    }
}

public enum PreMeetingBriefProposalFactory {
    /// A rebuilt presentation may resume the owner of a failed no-effect
    /// attempt. Any other proposal that settled or may have crossed the effect
    /// boundary cannot authorize this preview as if it were the same draft.
    public static func durableProposalID(
        requested: UUID,
        existing: SkillExecutionRecord?,
        idempotencyKey: String
    ) -> UUID? {
        guard let existing else { return requested }
        guard existing.skillID == PreMeetingBriefSkill.id,
              existing.skillVersion == PreMeetingBriefSkill.version,
              existing.idempotencyKey == idempotencyKey
        else { return nil }
        guard existing.proposalID == requested || existing.state == .failed else {
            return nil
        }
        return existing.proposalID
    }

    public static func proposal(
        proposalID: UUID = UUID(),
        eventID: String,
        at now: Date
    ) -> (proposal: SkillProposal, idempotencyKey: String)? {
        guard UpcomingEvent.isValidIdentity(eventID) else { return nil }
        return (
            SkillProposal(
                id: proposalID,
                definition: PreMeetingBriefSkill.definition,
                requestedCapabilities: [.readMeetingMaterial, .writeLocalDraft],
                arguments: [.text(eventID)],
                proposedAt: now),
            PreMeetingBriefSkill.idempotencyKey(forEvent: eventID)
        )
    }
}
