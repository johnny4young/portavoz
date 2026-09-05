import PortavozCore
import StorageKit

public protocol DecisionCommitmentBlockerStore: Sendable {
    func confirmDecisionCommitmentBlocker(
        _ confirmation: DecisionCommitmentBlockerConfirmation
    ) async throws -> DecisionCommitmentBlockerContinuity
    func applyDecisionCommitmentBlockerTransition(
        _ confirmation: DecisionBlockerTransitionConfirmation
    ) async throws -> DecisionCommitmentBlockerContinuity
    func decisionCommitmentBlockerContinuity(
        for blockerID: DecisionCommitmentBlockerID
    ) async throws -> DecisionCommitmentBlockerContinuity
    func activeDecisionCommitmentBlockers(
        for commitmentID: CommitmentID
    ) async throws -> [DecisionCommitmentBlockerContinuity]
}

extension MeetingStore: DecisionCommitmentBlockerStore {}

/// Explicit confirmation is the only boundary that can create causality.
public struct ConfirmDecisionCommitmentBlocker: ApplicationUseCase {
    private let store: any DecisionCommitmentBlockerStore

    public init(store: any DecisionCommitmentBlockerStore) {
        self.store = store
    }

    public func execute(
        _ confirmation: DecisionCommitmentBlockerConfirmation
    ) async throws -> DecisionCommitmentBlockerContinuity {
        try await store.confirmDecisionCommitmentBlocker(confirmation)
    }
}

public struct ManageDecisionCommitmentBlocker: ApplicationUseCase {
    private let store: any DecisionCommitmentBlockerStore

    public init(store: any DecisionCommitmentBlockerStore) {
        self.store = store
    }

    public func execute(
        _ confirmation: DecisionBlockerTransitionConfirmation
    ) async throws -> DecisionCommitmentBlockerContinuity {
        try await store.applyDecisionCommitmentBlockerTransition(confirmation)
    }
}

public struct LoadDecisionCommitmentBlocker: ApplicationUseCase {
    private let store: any DecisionCommitmentBlockerStore

    public init(store: any DecisionCommitmentBlockerStore) {
        self.store = store
    }

    public func execute(
        _ blockerID: DecisionCommitmentBlockerID
    ) async throws -> DecisionCommitmentBlockerContinuity {
        try await store.decisionCommitmentBlockerContinuity(for: blockerID)
    }
}

public struct LoadActiveCommitmentBlockers: ApplicationUseCase {
    private let store: any DecisionCommitmentBlockerStore

    public init(store: any DecisionCommitmentBlockerStore) {
        self.store = store
    }

    public func execute(
        _ commitmentID: CommitmentID
    ) async throws -> [DecisionCommitmentBlockerContinuity] {
        try await store.activeDecisionCommitmentBlockers(for: commitmentID)
    }
}
