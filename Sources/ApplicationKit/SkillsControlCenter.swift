import Foundation
import PortavozCore
import StorageKit

public enum SkillAvailability: Equatable, Sendable {
    /// A production proposal surface and effect adapter both exist.
    case available
    /// The skill contract exists, but its user-facing subject or platform
    /// adapter has not shipped. The pane must not imply it can run.
    case planned
}

public struct SkillCatalogueEntry: Equatable, Sendable, Identifiable {
    public let definition: SkillDefinition
    public let availability: SkillAvailability

    public var id: String { definition.id }

    public init(
        definition: SkillDefinition,
        availability: SkillAvailability
    ) {
        self.definition = definition
        self.availability = availability
    }
}

/// The one catalogue projected into the Skills management pane.
///
/// Contracts can predate surfaces. Keeping availability explicit prevents a
/// settings toggle from promising that reminder or calendar-event delivery is
/// wired merely because its pure skill definition already exists.
public enum SkillCatalogue {
    public static let entries: [SkillCatalogueEntry] = [
        SkillCatalogueEntry(
            definition: RecapDraftSkill.definition,
            availability: .available),
        SkillCatalogueEntry(
            definition: MeetingPackageExportSkill.definition,
            availability: .available),
        SkillCatalogueEntry(
            definition: ReminderDraftSkill.definition,
            availability: .available),
        SkillCatalogueEntry(
            definition: PreMeetingBriefSkill.definition,
            availability: .available),
        SkillCatalogueEntry(
            definition: EmailRecapDraftSkill.definition,
            availability: .available),
        SkillCatalogueEntry(
            definition: SecretGistPublishSkill.definition,
            availability: .available),
        SkillCatalogueEntry(
            definition: GitHubIssueCreateSkill.definition,
            availability: .available)
    ]
}

// ApplicationKit is a public SwiftPM library. Keep the former Phase-2 names as
// source-compatible migration shims even though the catalogue now contains an
// explicitly external Skill as well as local-only Skills.
@available(*, deprecated, renamed: "SkillAvailability")
public typealias LocalSkillAvailability = SkillAvailability
@available(*, deprecated, renamed: "SkillCatalogueEntry")
public typealias LocalSkillCatalogueEntry = SkillCatalogueEntry
@available(*, deprecated, renamed: "SkillCatalogue")
public typealias LocalSkillCatalogue = SkillCatalogue

public struct SkillControlCenterItem: Equatable, Sendable, Identifiable {
    public let definition: SkillDefinition
    public let availability: SkillAvailability
    /// The individual choice, independent from the global pause override.
    public let isEnabled: Bool

    public var id: String { definition.id }

    /// A disclosure derived from the executable capability contract rather
    /// than presentation copy. File, clipboard, and native-app effects can
    /// still land in user-selected synced destinations, so the local case
    /// deliberately promises only that Portavoz performs no direct network
    /// handoff.
    public var disclosureBoundary: SkillDisclosureBoundary {
        definition.declaresExternalEffect
            ? .externalHandoff
            : .noDirectNetworkHandoff
    }
}

public enum SkillDisclosureBoundary: Equatable, Sendable {
    case noDirectNetworkHandoff
    case externalHandoff
}

/// Whether the bounded receipt projection was read from durable authority.
///
/// Policy and receipt history are independent reads. A receipt-only failure
/// must not discard the verified policy or turn its controls into an error.
public enum SkillControlCenterReceiptLoadState: Equatable, Sendable {
    case verified
    case unavailable
}

public struct SkillControlCenterReceipt: Equatable, Sendable, Identifiable {
    public let proposalID: UUID
    public let skillID: String
    public let skillVersion: Int
    public let state: SkillExecutionState
    public let failureCategory: FailureCategory?
    public let attempt: Int
    public let updatedAt: Date

    public var id: UUID { proposalID }

    init(record: SkillExecutionRecord) {
        proposalID = record.proposalID
        skillID = record.skillID
        skillVersion = record.skillVersion
        state = record.state
        failureCategory = record.failureCategory
        attempt = record.attempt
        updatedAt = record.updatedAt
    }
}

public struct SkillControlCenterSnapshot: Equatable, Sendable {
    public static let defaultReceiptLimit = 20
    public static let maximumReceiptLimit = 50

    public let isPaused: Bool
    public let skills: [SkillControlCenterItem]
    public let receiptScope: SkillExecutionReviewScope
    public let receiptSkillID: String?
    public let receiptPeriod: SkillExecutionReviewPeriod
    public let receipts: [SkillControlCenterReceipt]
    /// Verified continuation evidence from one bounded sentinel row. The
    /// sentinel itself is never projected into `receipts`.
    public let hasMoreReceipts: Bool
    public let receiptLoadState: SkillControlCenterReceiptLoadState

    public init(
        isPaused: Bool,
        skills: [SkillControlCenterItem],
        receiptScope: SkillExecutionReviewScope,
        receipts: [SkillControlCenterReceipt],
        receiptSkillID: String? = nil,
        receiptPeriod: SkillExecutionReviewPeriod = .anytime,
        hasMoreReceipts: Bool = false,
        receiptLoadState: SkillControlCenterReceiptLoadState = .verified
    ) {
        self.isPaused = isPaused
        self.skills = skills
        self.receiptScope = receiptScope
        self.receiptSkillID = receiptSkillID
        self.receiptPeriod = receiptPeriod
        self.receipts = receipts
        self.hasMoreReceipts = hasMoreReceipts
        self.receiptLoadState = receiptLoadState
    }
}

public protocol SkillExecutionPolicyReading: Sendable {
    func skillExecutionPolicy() async throws -> SkillExecutionPolicy
}

public protocol SkillControlCenterStore: SkillExecutionPolicyReading, Sendable {
    func skillExecutions(
        scope: SkillExecutionReviewScope,
        skillID: String?,
        updatedAfter: Date?,
        limit: Int
    ) async throws -> [SkillExecutionRecord]
    func setAllSkillsPaused(_ isPaused: Bool, at timestamp: Date) async throws
    func setSkill(
        _ skillID: String,
        isEnabled: Bool,
        at timestamp: Date
    ) async throws
}

extension MeetingStore: SkillControlCenterStore {}

public struct LoadSkillControlCenterRequest: Equatable, Sendable {
    public let receiptScope: SkillExecutionReviewScope
    public let receiptSkillID: String?
    public let receiptPeriod: SkillExecutionReviewPeriod
    public let receiptReferenceDate: Date
    public let receiptLimit: Int

    public init(
        receiptScope: SkillExecutionReviewScope = .recent,
        receiptSkillID: String? = nil,
        receiptPeriod: SkillExecutionReviewPeriod = .anytime,
        receiptReferenceDate: Date = .now,
        receiptLimit: Int = SkillControlCenterSnapshot.defaultReceiptLimit
    ) {
        self.receiptScope = receiptScope
        self.receiptSkillID = receiptSkillID
        self.receiptPeriod = receiptPeriod
        self.receiptReferenceDate = receiptReferenceDate
        self.receiptLimit = min(
            max(receiptLimit, 1),
            SkillControlCenterSnapshot.maximumReceiptLimit)
    }
}

public enum LoadSkillControlCenterError: Error, Equatable, Sendable {
    case unknownReceiptSkillID
    case invalidReceiptReferenceDate
}

public struct LoadSkillControlCenter: ApplicationUseCase {
    private let store: any SkillControlCenterStore

    public init(store: any SkillControlCenterStore) {
        self.store = store
    }

    public func execute(
        _ request: LoadSkillControlCenterRequest
    ) async throws -> SkillControlCenterSnapshot {
        if let receiptSkillID = request.receiptSkillID,
           !SkillCatalogue.entries.contains(where: { $0.id == receiptSkillID }) {
            throw LoadSkillControlCenterError.unknownReceiptSkillID
        }
        let receiptUpdatedAfter = try Self.receiptUpdatedAfter(for: request)
        let receiptProbeLimit = request.receiptLimit + 1
        async let policy = store.skillExecutionPolicy()
        async let records = store.skillExecutions(
            scope: request.receiptScope,
            skillID: request.receiptSkillID,
            updatedAfter: receiptUpdatedAfter,
            limit: receiptProbeLimit)
        let resolvedPolicy = try await policy
        let resolvedRecords: [SkillExecutionRecord]
        let receiptLoadState: SkillControlCenterReceiptLoadState
        do {
            resolvedRecords = try await records
            receiptLoadState = .verified
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            resolvedRecords = []
            receiptLoadState = .unavailable
        }
        return SkillControlCenterSnapshot(
            isPaused: resolvedPolicy.isPaused,
            skills: SkillCatalogue.entries.map { entry in
                SkillControlCenterItem(
                    definition: entry.definition,
                    availability: entry.availability,
                    isEnabled: resolvedPolicy.isIndividuallyEnabled(
                        skillID: entry.id))
            },
            receiptScope: request.receiptScope,
            receipts: resolvedRecords.prefix(request.receiptLimit).map(
                SkillControlCenterReceipt.init(record:)),
            receiptSkillID: request.receiptSkillID,
            receiptPeriod: request.receiptPeriod,
            hasMoreReceipts:
                receiptLoadState == .verified
                    && resolvedRecords.count > request.receiptLimit,
            receiptLoadState: receiptLoadState)
    }

    private static func receiptUpdatedAfter(
        for request: LoadSkillControlCenterRequest
    ) throws -> Date? {
        let reference = request.receiptReferenceDate
            .timeIntervalSinceReferenceDate
        guard reference.isFinite else {
            throw LoadSkillControlCenterError.invalidReceiptReferenceDate
        }
        let seconds: TimeInterval? = switch request.receiptPeriod {
        case .anytime: nil
        case .pastDay: 24 * 60 * 60
        case .pastWeek: 7 * 24 * 60 * 60
        case .pastMonth: 30 * 24 * 60 * 60
        }
        guard let seconds else { return nil }
        let lowerBound = request.receiptReferenceDate
            .addingTimeInterval(-seconds)
        guard lowerBound.timeIntervalSinceReferenceDate.isFinite else {
            throw LoadSkillControlCenterError.invalidReceiptReferenceDate
        }
        return lowerBound
    }
}

public enum ManageSkillControlAction: Equatable, Sendable {
    case setPaused(Bool)
    case setSkillEnabled(skillID: String, isEnabled: Bool)
}

public enum ManageSkillControlRejection: Equatable, Sendable {
    case unknownSkill
    case unavailableSkill
}

public enum ManageSkillControlOutcome: Equatable, Sendable {
    case updated
    case rejected(ManageSkillControlRejection)
}

public struct ManageSkillControl: ApplicationUseCase {
    private let store: any SkillControlCenterStore
    private let now: @Sendable () -> Date

    public init(
        store: any SkillControlCenterStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    public func execute(
        _ action: ManageSkillControlAction
    ) async throws -> ManageSkillControlOutcome {
        switch action {
        case .setPaused(let isPaused):
            try await store.setAllSkillsPaused(isPaused, at: now())
        case .setSkillEnabled(let skillID, let isEnabled):
            guard let entry = SkillCatalogue.entries.first(where: {
                $0.id == skillID
            }) else { return .rejected(.unknownSkill) }
            guard entry.availability == .available else {
                return .rejected(.unavailableSkill)
            }
            try await store.setSkill(
                skillID,
                isEnabled: isEnabled,
                at: now())
        }
        return .updated
    }
}
