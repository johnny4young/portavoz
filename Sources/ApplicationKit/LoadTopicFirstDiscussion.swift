import PortavozCore
import StorageKit

public protocol TopicFirstDiscussionReading: Sendable {
    func topicFirstDiscussion(
        _ query: TopicFirstDiscussionQuery
    ) async throws -> MeetingMemoryGraphQueryResult
}

extension MeetingStore: TopicFirstDiscussionReading {}

/// Application boundary for one source-backed first-discussion fact. Topic
/// discovery and answer synthesis remain separate concerns.
public struct LoadTopicFirstDiscussion: ApplicationUseCase {
    private let repository: any TopicFirstDiscussionReading

    public init(repository: any TopicFirstDiscussionReading) {
        self.repository = repository
    }

    public func execute(
        _ query: TopicFirstDiscussionQuery
    ) async throws -> MeetingMemoryGraphQueryResult {
        try await repository.topicFirstDiscussion(query)
    }
}
