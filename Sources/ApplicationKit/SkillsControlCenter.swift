import Foundation
import PortavozCore
import StorageKit

public enum LocalSkillAvailability: Equatable, Sendable {
    /// A production proposal surface and effect adapter both exist.
    case available
    /// The skill contract exists, but its user-facing subject or platform
    /// adapter has not shipped. The pane must not imply it can run.
    case planned
}

public struct LocalSkillCatalogueEntry: Equatable, Sendable, Identifiable {
    public let definition: SkillDefinition
    public let availability: LocalSkillAvailability

    public var id: String { definition.id }

    public init(
        definition: SkillDefinition,
        availability: LocalSkillAvailability
    ) {
        self.definition = definition
        self.availability = availability
    }
}

/// The one catalogue projected into the Phase-2 management pane.
///
/// Contracts can predate surfaces. Keeping availability explicit prevents a
/// settings toggle from promising that reminder or calendar-event delivery is
/// wired merely because its pure skill definition already exists.
public enum LocalSkillCatalogue {
    public static let entries: [LocalSkillCatalogueEntry] = [
        LocalSkillCatalogueEntry(
            definition: RecapDraftSkill.definition,
            availability: .available),
        LocalSkillCatalogueEntry(
            definition: MeetingPackageExportSkill.definition,
            availability: .available),
        LocalSkillCatalogueEntry(
            definition: ReminderDraftSkill.definition,
            availability: .planned),
        LocalSkillCatalogueEntry(
            definition: PreMeetingBriefSkill.definition,
            availability: .planned)
    ]
}

public struct SkillControlCenterItem: Equatable, Sendable, Identifiable {
    public let definition: SkillDefinition
    public let availability: LocalSkillAvailability
    /// The individual choice, independent from the global pause override.
    public let isEnabled: Bool

    public var id: String { definition.id }
}

public struct SkillControlCenterReceipt: Equatable, Sendable, Identifiable {
    public let proposalID: UUID
    public let skillID: String
    public let skillVersion: Int
    public let state: SkillExecutionState
    public let attempt: Int
    public let updatedAt: Date

    public var id: UUID { proposalID }

    init(record: SkillExecutionRecord) {
        proposalID = record.proposalID
        skillID = record.skillID
        skillVersion = record.skillVersion
        state = record.state
        attempt = record.attempt
        updatedAt = record.updatedAt
    }
}

public struct SkillControlCenterSnapshot: Equatable, Sendable {
    public static let defaultReceiptLimit = 20
    public static let maximumReceiptLimit = 50

    public let isPaused: Bool
    public let skills: [SkillControlCenterItem]
    public let receipts: [SkillControlCenterReceipt]

    public init(
        isPaused: Bool,
        skills: [SkillControlCenterItem],
        receipts: [SkillControlCenterReceipt]
    ) {
        self.isPaused = isPaused
        self.skills = skills
        self.receipts = receipts
    }
}

public protocol SkillExecutionPolicyReading: Sendable {
    func skillExecutionPolicy() async throws -> SkillExecutionPolicy
}

public protocol SkillControlCenterStore: SkillExecutionPolicyReading, Sendable {
    func recentSkillExecutions(limit: Int) async throws -> [SkillExecutionRecord]
    func setAllSkillsPaused(_ isPaused: Bool, at timestamp: Date) async throws
    func setSkill(
        _ skillID: String,
        isEnabled: Bool,
        at timestamp: Date
    ) async throws
}

extension MeetingStore: SkillControlCenterStore {}

public struct LoadSkillControlCenterRequest: Equatable, Sendable {
    public let receiptLimit: Int

    public init(
        receiptLimit: Int = SkillControlCenterSnapshot.defaultReceiptLimit
    ) {
        self.receiptLimit = min(
            max(receiptLimit, 1),
            SkillControlCenterSnapshot.maximumReceiptLimit)
    }
}

public struct LoadSkillControlCenter: ApplicationUseCase {
    private let store: any SkillControlCenterStore

    public init(store: any SkillControlCenterStore) {
        self.store = store
    }

    public func execute(
        _ request: LoadSkillControlCenterRequest
    ) async throws -> SkillControlCenterSnapshot {
        async let policy = store.skillExecutionPolicy()
        async let records = store.recentSkillExecutions(
            limit: request.receiptLimit)
        let (resolvedPolicy, resolvedRecords) = try await (policy, records)
        return SkillControlCenterSnapshot(
            isPaused: resolvedPolicy.isPaused,
            skills: LocalSkillCatalogue.entries.map { entry in
                SkillControlCenterItem(
                    definition: entry.definition,
                    availability: entry.availability,
                    isEnabled: resolvedPolicy.isIndividuallyEnabled(
                        skillID: entry.id))
            },
            receipts: resolvedRecords.map(SkillControlCenterReceipt.init(record:)))
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
            guard let entry = LocalSkillCatalogue.entries.first(where: {
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
