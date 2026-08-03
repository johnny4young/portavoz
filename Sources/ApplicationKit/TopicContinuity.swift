import Foundation
import PortavozCore
import StorageKit

/// Narrow topic-continuity port. Candidate lookup and mutation remain separate
/// so an alias or similarity result cannot confirm itself.
public protocol TopicContinuityStore: Sendable {
    func topics(matchingAlias alias: String) async throws -> [Topic]
    func createTopicAndLink(
        _ proposal: TopicLinkProposal
    ) async throws -> ConfirmedTopicLink
    func linkTopic(
        _ proposal: TopicLinkProposal,
        to topicID: TopicID
    ) async throws -> ConfirmedTopicLink
    func mergeTopics(
        sourceTopicID: TopicID,
        into targetTopicID: TopicID,
        eventID: TopicIdentityEventID,
        at timestamp: Date
    ) async throws -> ConfirmedTopicIdentityChange
    func splitTopic(
        sourceTopicID: TopicID,
        from targetTopicID: TopicID,
        eventID: TopicIdentityEventID,
        at timestamp: Date
    ) async throws -> ConfirmedTopicIdentityChange
    func topicEvidence(
        for topicID: TopicID
    ) async throws -> [TopicMeetingEvidence]
}

extension MeetingStore: TopicContinuityStore {}

public struct FindTopics: ApplicationUseCase {
    private let store: any TopicContinuityStore

    public init(store: any TopicContinuityStore) {
        self.store = store
    }

    public func execute(_ alias: String) async throws -> [Topic] {
        try await store.topics(matchingAlias: alias)
    }
}

public enum TopicSelection: Equatable, Sendable {
    case createDistinct
    case existing(TopicID)
}

public struct ConfirmTopicLinkRequest: Equatable, Sendable {
    public let proposal: TopicLinkProposal
    public let selection: TopicSelection

    public init(proposal: TopicLinkProposal, selection: TopicSelection) {
        self.proposal = proposal
        self.selection = selection
    }
}

/// The only application command that can turn a manual or generated proposal
/// into a durable meeting/topic edge.
public struct ConfirmTopicLink: ApplicationUseCase {
    private let store: any TopicContinuityStore

    public init(store: any TopicContinuityStore) {
        self.store = store
    }

    public func execute(_ request: ConfirmTopicLinkRequest) async throws
        -> ConfirmedTopicLink {
        switch request.selection {
        case .createDistinct:
            return try await store.createTopicAndLink(request.proposal)
        case .existing(let topicID):
            return try await store.linkTopic(request.proposal, to: topicID)
        }
    }
}

public struct TopicIdentityChangeRequest: Equatable, Sendable {
    public let sourceTopicID: TopicID
    public let targetTopicID: TopicID
    public let eventID: TopicIdentityEventID
    public let timestamp: Date

    public init(
        sourceTopicID: TopicID,
        targetTopicID: TopicID,
        eventID: TopicIdentityEventID = TopicIdentityEventID(),
        timestamp: Date = Date()
    ) {
        self.sourceTopicID = sourceTopicID
        self.targetTopicID = targetTopicID
        self.eventID = eventID
        self.timestamp = timestamp
    }
}

public struct ConfirmTopicMerge: ApplicationUseCase {
    private let store: any TopicContinuityStore

    public init(store: any TopicContinuityStore) {
        self.store = store
    }

    public func execute(_ request: TopicIdentityChangeRequest) async throws
        -> ConfirmedTopicIdentityChange {
        try await store.mergeTopics(
            sourceTopicID: request.sourceTopicID,
            into: request.targetTopicID,
            eventID: request.eventID,
            at: request.timestamp)
    }
}

public struct ConfirmTopicSplit: ApplicationUseCase {
    private let store: any TopicContinuityStore

    public init(store: any TopicContinuityStore) {
        self.store = store
    }

    public func execute(_ request: TopicIdentityChangeRequest) async throws
        -> ConfirmedTopicIdentityChange {
        try await store.splitTopic(
            sourceTopicID: request.sourceTopicID,
            from: request.targetTopicID,
            eventID: request.eventID,
            at: request.timestamp)
    }
}

public struct LoadTopicEvidence: ApplicationUseCase {
    private let store: any TopicContinuityStore

    public init(store: any TopicContinuityStore) {
        self.store = store
    }

    public func execute(_ topicID: TopicID) async throws -> [TopicMeetingEvidence] {
        try await store.topicEvidence(for: topicID)
    }
}
