import PortavozCore
import StorageKit

/// Write-only seam shared by every released proposal producer. A surface must
/// reconcile its bounded candidates before returning an offer; Settings never
/// reconstructs proposals by scanning transient presentation state.
public protocol SkillOfferAuthorityWriting: Sendable {
    func reconcileSkillOffers(
        candidateOfferKeys: [String],
        active offers: [SkillOfferRegistration]
    ) async throws
}

extension MeetingStore: SkillOfferAuthorityWriting {}
