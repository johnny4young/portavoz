import Foundation
import PortavozCore

extension MeetingBriefLines.Occurrence {
    public init(event: UpcomingEvent) {
        self.init(eventID: event.id, startAt: event.startDate)
    }
}

public protocol MeetingBriefLinesReading: Sendable {
    /// nil when the occurrence has no recorded source.
    func meetingBriefLines(
        for occurrence: MeetingBriefLines.Occurrence
    ) async throws -> MeetingBriefLines?
}

/// What each person said in an upcoming event's previous occurrence, for
/// Today's preview. The previous occurrence is recorded when it differs from
/// the cached source; without one, the cached source stays.
public struct LoadMeetingBriefLines: ApplicationUseCase {
    private let lines: any MeetingBriefLinesReading
    private let sources: any MeetingBriefSourceRecording

    public init(lines: any MeetingBriefLinesReading, sources: any MeetingBriefSourceRecording) {
        self.lines = lines
        self.sources = sources
    }

    public func execute(_ event: UpcomingEvent) async throws -> MeetingBriefLines? {
        let occurrence = MeetingBriefLines.Occurrence(event: event)
        async let cachedLines = lines.meetingBriefLines(for: occurrence)
        let previous = try await sources.previousMeetingBriefOccurrence(
            eventID: event.id, title: event.title, before: event.startDate)
        let cached = try await cachedLines
        guard let previous, previous != cached?.sourceMeetingID else { return cached }
        try await sources.recordMeetingBriefSource(
            eventID: event.id, eventStartAt: event.startDate, sourceMeetingID: previous)
        return try await lines.meetingBriefLines(for: occurrence)
    }
}
