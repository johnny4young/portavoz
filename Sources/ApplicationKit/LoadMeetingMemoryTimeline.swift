import PortavozCore
import StorageKit

public protocol MeetingMemoryTimelineReading: Sendable {
    func meetingMemoryTimeline(
        _ query: MeetingMemoryTimelineQuery
    ) async throws -> MeetingMemoryTimelineResult
}

extension MeetingStore: MeetingMemoryTimelineReading {}

/// Application boundary for correction-aware longitudinal reads. Discovery by
/// display name or topic label happens before this use case; callers provide
/// one exact canonical identity and receive only typed graph facts.
public struct LoadMeetingMemoryTimeline: ApplicationUseCase {
    private let repository: any MeetingMemoryTimelineReading

    public init(repository: any MeetingMemoryTimelineReading) {
        self.repository = repository
    }

    public func execute(
        _ query: MeetingMemoryTimelineQuery
    ) async throws -> MeetingMemoryTimelineResult {
        try await repository.meetingMemoryTimeline(query)
    }
}
