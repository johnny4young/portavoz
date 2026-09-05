import Foundation
import PortavozCore
import StorageKit

/// Decision candidates and user truth remain separate operations. Loading one
/// generated observation never grants confirmation or relationship authority.
public protocol DecisionContinuityStore: Sendable {
    func decisionObservation(
        for observationID: SummaryDecisionID
    ) async throws -> DecisionObservation
    func confirmDecision(
        _ confirmation: DecisionConfirmation
    ) async throws -> DecisionContinuity
    func linkDecisionSource(
        _ confirmation: DecisionSourceConfirmation
    ) async throws -> DecisionContinuity
    func confirmDecisionRelationship(
        _ confirmation: DecisionRelationshipConfirmation
    ) async throws -> DecisionContinuity
    func decisionContinuity(
        for decisionID: DecisionID
    ) async throws -> DecisionContinuity
}

extension MeetingStore: DecisionContinuityStore {}

public struct LoadDecisionObservation: ApplicationUseCase {
    private let store: any DecisionContinuityStore

    public init(store: any DecisionContinuityStore) {
        self.store = store
    }

    public func execute(
        _ observationID: SummaryDecisionID
    ) async throws -> DecisionObservation {
        try await store.decisionObservation(for: observationID)
    }
}

/// The only command that promotes one generated decision observation into a
/// new durable decision identity.
public struct ConfirmObservedDecision: ApplicationUseCase {
    private let store: any DecisionContinuityStore

    public init(store: any DecisionContinuityStore) {
        self.store = store
    }

    public func execute(
        _ confirmation: DecisionConfirmation
    ) async throws -> DecisionContinuity {
        try await store.confirmDecision(confirmation)
    }
}

/// Explicitly accepts one later source as evidence for an existing current
/// decision. Semantic retrieval may suggest this action but cannot execute it.
public struct ConfirmDecisionSource: ApplicationUseCase {
    private let store: any DecisionContinuityStore

    public init(store: any DecisionContinuityStore) {
        self.store = store
    }

    public func execute(
        _ confirmation: DecisionSourceConfirmation
    ) async throws -> DecisionContinuity {
        try await store.linkDecisionSource(confirmation)
    }
}

public struct ConfirmDecisionRelationship: ApplicationUseCase {
    private let store: any DecisionContinuityStore

    public init(store: any DecisionContinuityStore) {
        self.store = store
    }

    public func execute(
        _ confirmation: DecisionRelationshipConfirmation
    ) async throws -> DecisionContinuity {
        try await store.confirmDecisionRelationship(confirmation)
    }
}

public struct LoadDecisionContinuity: ApplicationUseCase {
    private let store: any DecisionContinuityStore

    public init(store: any DecisionContinuityStore) {
        self.store = store
    }

    public func execute(_ decisionID: DecisionID) async throws -> DecisionContinuity {
        try await store.decisionContinuity(for: decisionID)
    }
}
