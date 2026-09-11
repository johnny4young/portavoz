import Foundation
import PortavozCore
import StorageKit

/// Decision↔topic aboutness is user truth, never inference. Semantic
/// retrieval may *suggest* a link; only these commands can create or withdraw
/// one, and each demands evidence the decision already owns.
public protocol DecisionTopicAuthorityStore: Sendable {
    func confirmDecisionTopicLink(
        _ confirmation: DecisionTopicLinkConfirmation
    ) async throws -> DecisionTopicLinkContinuity
    func retractDecisionTopicLink(
        _ retraction: DecisionTopicLinkRetraction
    ) async throws -> DecisionTopicLinkContinuity
    func decisionTopicLinks(
        for decisionID: DecisionID
    ) async throws -> [DecisionTopicLinkContinuity]
    func decisionTopicLinks(
        for topicID: TopicID
    ) async throws -> [DecisionTopicLinkContinuity]
}

extension MeetingStore: DecisionTopicAuthorityStore {}

/// The only command that makes a decision *about* a topic.
public struct ConfirmDecisionTopicLink: ApplicationUseCase {
    private let store: any DecisionTopicAuthorityStore

    public init(store: any DecisionTopicAuthorityStore) {
        self.store = store
    }

    public func execute(
        _ confirmation: DecisionTopicLinkConfirmation
    ) async throws -> DecisionTopicLinkContinuity {
        try await store.confirmDecisionTopicLink(confirmation)
    }
}

public struct RetractDecisionTopicLink: ApplicationUseCase {
    private let store: any DecisionTopicAuthorityStore

    public init(store: any DecisionTopicAuthorityStore) {
        self.store = store
    }

    public func execute(
        _ retraction: DecisionTopicLinkRetraction
    ) async throws -> DecisionTopicLinkContinuity {
        try await store.retractDecisionTopicLink(retraction)
    }
}

public struct LoadDecisionTopicLinks: ApplicationUseCase {
    public enum Subject: Equatable, Sendable {
        case decision(DecisionID)
        case topic(TopicID)
    }

    private let store: any DecisionTopicAuthorityStore

    public init(store: any DecisionTopicAuthorityStore) {
        self.store = store
    }

    public func execute(
        _ subject: Subject
    ) async throws -> [DecisionTopicLinkContinuity] {
        switch subject {
        case .decision(let decisionID):
            try await store.decisionTopicLinks(for: decisionID)
        case .topic(let topicID):
            try await store.decisionTopicLinks(for: topicID)
        }
    }
}
