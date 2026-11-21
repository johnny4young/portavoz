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
/// Today's preview. Reads the cache; an occurrence without a source records
/// its previous same-title meeting first.
public struct LoadMeetingBriefLines: ApplicationUseCase {
    private let lines: any MeetingBriefLinesReading
    private let sources: any MeetingBriefSourceRecording

    public init(lines: any MeetingBriefLinesReading, sources: any MeetingBriefSourceRecording) {
        self.lines = lines
        self.sources = sources
    }

    public func execute(_ event: UpcomingEvent) async throws -> MeetingBriefLines? {
        let occurrence = MeetingBriefLines.Occurrence(event: event)
        if let cached = try await lines.meetingBriefLines(for: occurrence) { return cached }
        guard let previous = try await sources.previousMeetingBriefOccurrence(
            title: event.title, before: event.startDate)
        else { return nil }
        try await sources.recordMeetingBriefSource(
            eventID: event.id, eventStartAt: event.startDate, sourceMeetingID: previous)
        return try await lines.meetingBriefLines(for: occurrence)
    }
}
