import Foundation
import PortavozCore
import StorageKit

/// One skill Portavoz proposes for one meeting — the banner's row (Q12/D316).
///
/// The offer key is the stable intent identity: it survives banner
/// regeneration, anchors durable dismissal, and for recap it IS the
/// idempotency key, so a succeeded execution retires the offer.
public struct MeetingSkillOffer: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case recapDraft = "recap-draft"
        case emailRecapDraft = "email-recap-draft"
        case secretGistPublish = "secret-gist-publish"
        case packageExport = "package-export"
    }

    public let kind: Kind
    public let meetingID: MeetingID
    public let offerKey: String

    public var id: String { offerKey }

    public init(kind: Kind, meetingID: MeetingID) {
        self.kind = kind
        self.meetingID = meetingID
        switch kind {
        case .recapDraft:
            offerKey = RecapDraftSkill.idempotencyKey(for: meetingID)
        case .emailRecapDraft:
            offerKey = EmailRecapDraftSkill.idempotencyKey(for: meetingID)
        case .secretGistPublish:
            offerKey = SecretGistPublishSkill.idempotencyKey(for: meetingID)
        case .packageExport:
            // Deliberately destination-free: the export key includes the path
            // the user picks at confirm time, but "stop offering this" is a
            // decision about the meeting, not about one destination.
            offerKey = "\(MeetingPackageExportSkill.id):\(meetingID.rawValue.uuidString)"
        }
    }

    public var skillID: String {
        switch kind {
        case .recapDraft: RecapDraftSkill.id
        case .emailRecapDraft: EmailRecapDraftSkill.id
        case .secretGistPublish: SecretGistPublishSkill.id
        case .packageExport: MeetingPackageExportSkill.id
        }
    }

    public var definition: SkillDefinition {
        switch kind {
        case .recapDraft: RecapDraftSkill.definition
        case .emailRecapDraft: EmailRecapDraftSkill.definition
        case .secretGistPublish: SecretGistPublishSkill.definition
        case .packageExport: MeetingPackageExportSkill.definition
        }
    }

    public func registration(at timestamp: Date) -> SkillOfferRegistration {
        SkillOfferRegistration(
            offerKey: offerKey,
            definition: definition,
            requestedInputDataClasses: definition.inputDataClasses,
            subject: .meeting(meetingID),
            reason: .meetingSummaryReady,
            proposedAt: timestamp)
    }
}

/// What the confirmation sheet shows — computed read-only, before anything is
/// claimed. The preview must be the exact artifact: for recap, the composed
/// subject and body the delivery will hand over verbatim.
public enum MeetingSkillPreview: Equatable, Sendable {
    case recap(subject: String, body: String)
    case emailDraft(subject: String, body: String)
    case secretGist(SecretGistDraft)
    case packageExport(meetingTitle: String, destination: String)
}

/// The slice of MeetingStore the offer policy reads.
public protocol MeetingSkillOfferStore:
    SkillExecutionPolicyReading,
    SkillOfferAuthorityWriting,
    Sendable {
    func dismissedSkillOffers(offerKeys: [String]) async throws -> Set<String>
    func skillExecutions(
        idempotencyKeys: [String]
    ) async throws -> [SkillExecutionRecord]
    func skillExecutions(
        idempotencyKeyPrefix prefix: String
    ) async throws -> [SkillExecutionRecord]
    func dismissSkillOffer(
        offerKey: String,
        skillID: String,
        at timestamp: Date
    ) async throws
}

extension MeetingStore: MeetingSkillOfferStore {}

/// Decides which offers the banner may show. Pure policy over durable state:
/// a dismissed offer never returns, a succeeded recap retires its offer
/// (the draft exists; re-drafting is the manual sheet's job), and export
/// stays offered because each destination is a distinct intended effect.
public struct LoadMeetingSkillOffersRequest: Equatable, Sendable {
    public let meetingID: MeetingID
    public let hasSummary: Bool

    public init(meetingID: MeetingID, hasSummary: Bool) {
        self.meetingID = meetingID
        self.hasSummary = hasSummary
    }
}

public struct LoadMeetingSkillOffers: ApplicationUseCase {
    private let store: any MeetingSkillOfferStore
    private let now: @Sendable () -> Date

    public init(
        store: any MeetingSkillOfferStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    public func execute(
        _ request: LoadMeetingSkillOffersRequest
    ) async throws -> [MeetingSkillOffer] {
        let meetingID = request.meetingID
        let hasSummary = request.hasSummary
        let candidates = [
            MeetingSkillOffer(kind: .recapDraft, meetingID: meetingID),
            MeetingSkillOffer(kind: .emailRecapDraft, meetingID: meetingID),
            MeetingSkillOffer(kind: .secretGistPublish, meetingID: meetingID),
            MeetingSkillOffer(kind: .packageExport, meetingID: meetingID)
        ]
        let candidateKeys = candidates.map(\.offerKey)
        guard hasSummary else {
            try await store.reconcileSkillOffers(
                candidateOfferKeys: candidateKeys,
                active: [])
            return []
        }
        let policy = try await store.skillExecutionPolicy()
        guard !policy.isPaused else {
            try await store.reconcileSkillOffers(
                candidateOfferKeys: candidateKeys,
                active: [])
            return []
        }
        let dismissed = try await store.dismissedSkillOffers(
            offerKeys: candidates.map(\.offerKey))
        let eligible = candidates.filter {
            policy.isIndividuallyEnabled(skillID: $0.skillID)
                && !dismissed.contains($0.offerKey)
        }
        let oneShotKeys = eligible.compactMap { offer in
            switch offer.kind {
            case .recapDraft, .emailRecapDraft, .secretGistPublish:
                offer.offerKey
            case .packageExport: nil
            }
        }
        let oneShotExecutions = try await store.skillExecutions(
            idempotencyKeys: oneShotKeys)
        let unavailableOneShotKeys = Set(oneShotExecutions.compactMap { record in
            let mayHaveCompleted = record.state == .succeeded
                || record.state == .executing
            let remoteMutationIsAmbiguous =
                record.skillID == SecretGistPublishSkill.id
                && record.state == .failed
            return mayHaveCompleted || remoteMutationIsAmbiguous
                ? record.idempotencyKey
                : nil
        })
        let offers = eligible.filter {
            !unavailableOneShotKeys.contains($0.offerKey)
        }
        let timestamp = now()
        try await store.reconcileSkillOffers(
            candidateOfferKeys: candidateKeys,
            active: offers.map { $0.registration(at: timestamp) })
        return offers
    }
}

/// Receipts the meeting's trust section renders — every durable execution
/// whose intent belongs to this meeting, newest first.
public struct MeetingSkillReceipt: Equatable, Sendable, Identifiable {
    public let proposalID: UUID
    public let skillID: String
    public let skillVersion: Int
    public let state: SkillExecutionState
    public let updatedAt: Date

    public var id: UUID { proposalID }

    public init(record: SkillExecutionRecord) {
        proposalID = record.proposalID
        skillID = record.skillID
        skillVersion = record.skillVersion
        state = record.state
        updatedAt = record.updatedAt
    }
}

public struct LoadMeetingSkillReceipts: ApplicationUseCase {
    private let store: any MeetingSkillOfferStore

    public init(store: any MeetingSkillOfferStore) {
        self.store = store
    }

    public func execute(
        _ meetingID: MeetingID
    ) async throws -> [MeetingSkillReceipt] {
        let key = meetingID.rawValue.uuidString
        var records = try await store.skillExecutions(idempotencyKeys: [
            "\(RecapDraftSkill.id):\(key)",
            "\(EmailRecapDraftSkill.id):\(key)",
            "\(SecretGistPublishSkill.id):\(key)"
        ])
        records += try await store.skillExecutions(
            idempotencyKeyPrefix: "\(MeetingPackageExportSkill.id):\(key):")
        return records
            .sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.proposalID.uuidString < $1.proposalID.uuidString
            }
            .map(MeetingSkillReceipt.init(record:))
    }
}

/// Builds the exact proposal one confirmed offer executes. Pure, so tests can
/// pin the arguments and the idempotency key without a store.
public enum MeetingSkillProposalFactory {
    public static func recapProposal(
        proposalID: UUID = UUID(),
        meetingID: MeetingID,
        at now: Date
    ) -> (proposal: SkillProposal, idempotencyKey: String) {
        (
            SkillProposal(
                id: proposalID,
                definition: RecapDraftSkill.definition,
                requestedCapabilities: [.readMeetingMaterial, .writeLocalDraft],
                requestedInputDataClasses: RecapDraftSkill.definition.inputDataClasses,
                arguments: [.meeting(meetingID)],
                proposedAt: now),
            RecapDraftSkill.idempotencyKey(for: meetingID)
        )
    }

    public static func packageExportProposal(
        proposalID: UUID = UUID(),
        meetingID: MeetingID,
        destination: String,
        at now: Date
    ) -> (proposal: SkillProposal, idempotencyKey: String) {
        (
            SkillProposal(
                id: proposalID,
                definition: MeetingPackageExportSkill.definition,
                requestedCapabilities: [.readMeetingMaterial, .writeLocalFile],
                requestedInputDataClasses:
                    MeetingPackageExportSkill.definition.inputDataClasses,
                arguments: [.meeting(meetingID), .text(destination)],
                proposedAt: now),
            MeetingPackageExportSkill.idempotencyKey(
                for: meetingID,
                destination: destination)
        )
    }

    public static func emailRecapDraftProposal(
        proposalID: UUID = UUID(),
        meetingID: MeetingID,
        at now: Date
    ) -> (proposal: SkillProposal, idempotencyKey: String) {
        (
            SkillProposal(
                id: proposalID,
                definition: EmailRecapDraftSkill.definition,
                requestedCapabilities: [.readMeetingMaterial, .sendRemote],
                requestedInputDataClasses:
                    EmailRecapDraftSkill.definition.inputDataClasses,
                arguments: [.meeting(meetingID)],
                proposedAt: now),
            EmailRecapDraftSkill.idempotencyKey(for: meetingID)
        )
    }

    public static func secretGistPublishProposal(
        proposalID: UUID = UUID(),
        meetingID: MeetingID,
        at now: Date
    ) -> (proposal: SkillProposal, idempotencyKey: String) {
        (
            SkillProposal(
                id: proposalID,
                definition: SecretGistPublishSkill.definition,
                requestedCapabilities: [.readMeetingMaterial, .sendRemote],
                requestedInputDataClasses:
                    SecretGistPublishSkill.definition.inputDataClasses,
                arguments: [.meeting(meetingID)],
                proposedAt: now),
            SecretGistPublishSkill.idempotencyKey(for: meetingID)
        )
    }
}
