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
    private let telemetry: MeetingMemoryGraphQueryTelemetry

    public init(
        repository: any TopicFirstDiscussionReading,
        telemetry: MeetingMemoryGraphQueryTelemetry = .disabled
    ) {
        self.repository = repository
        self.telemetry = telemetry
    }

    public func execute(
        _ query: TopicFirstDiscussionQuery
    ) async throws -> MeetingMemoryGraphQueryResult {
        try await telemetry.measure(.topicFirstDiscussion) {
            try await repository.topicFirstDiscussion(query)
        }
    }
}
