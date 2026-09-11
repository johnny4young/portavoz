import Foundation
import PortavozCore
import StorageKit

public protocol StandingSkillAutomationCenterStore:
    StandingSkillRuleStore,
    Sendable {
    func standingSkillExecutionReceipts(
        limit: Int
    ) async throws -> [StandingSkillExecutionReceipt]
    func standingSkillArtifact(
        proposalID: UUID
    ) async throws -> StandingSkillArtifact?
}

extension MeetingStore: StandingSkillAutomationCenterStore {}

public struct StandingSkillAutomationCenterRequest: Equatable, Sendable {
    public let historyLimit: Int

    public init(historyLimit: Int = 20) {
        self.historyLimit = min(max(historyLimit, 1), 50)
    }
}

public struct StandingSkillAutomationCenterSnapshot: Equatable, Sendable {
    public static let defaultHistoryLimit = 20
    public static let maximumHistoryLimit = 50

    public let controls: StandingSkillRuleControlSnapshot
    public let history: [StandingSkillExecutionReceipt]
    public let hasMoreHistory: Bool

    public init(
        controls: StandingSkillRuleControlSnapshot,
        history: [StandingSkillExecutionReceipt],
        hasMoreHistory: Bool
    ) {
        self.controls = controls
        self.history = history
        self.hasMoreHistory = hasMoreHistory
    }
}

/// One fail-closed control projection over two independent immutable
/// authorities. Presentation adopts neither rules nor history when either
/// bounded read fails.
public struct LoadStandingSkillAutomationCenter: ApplicationUseCase {
    private let store: any StandingSkillAutomationCenterStore

    public init(store: any StandingSkillAutomationCenterStore) {
        self.store = store
    }

    public func execute(
        _ request: StandingSkillAutomationCenterRequest
    ) async throws -> StandingSkillAutomationCenterSnapshot {
        let limit = min(
            max(request.historyLimit, 1),
            StandingSkillAutomationCenterSnapshot.maximumHistoryLimit)
        async let controls = LoadStandingSkillRules(store: store).execute(())
        async let history = store.standingSkillExecutionReceipts(
            limit: limit + 1)
        let resolvedControls = try await controls
        let resolvedHistory = try await history
        return StandingSkillAutomationCenterSnapshot(
            controls: resolvedControls,
            history: Array(resolvedHistory.prefix(limit)),
            hasMoreHistory: resolvedHistory.count > limit)
    }
}

public enum LoadStandingSkillBriefError: Error, Equatable, Sendable {
    case unavailable
    case invalidArtifact
}

/// Loads content only after the user selects one succeeded standing receipt.
/// The control/history projection itself therefore remains content-free.
public struct LoadStandingSkillBrief: ApplicationUseCase {
    private let store: any StandingSkillAutomationCenterStore

    public init(store: any StandingSkillAutomationCenterStore) {
        self.store = store
    }

    public func execute(_ proposalID: UUID) async throws -> MeetingBrief {
        guard let artifact = try await store.standingSkillArtifact(
            proposalID: proposalID)
        else { throw LoadStandingSkillBriefError.unavailable }
        do {
            return try StandingPreMeetingBriefArtifactCodec.decode(artifact)
        } catch {
            throw LoadStandingSkillBriefError.invalidArtifact
        }
    }
}
