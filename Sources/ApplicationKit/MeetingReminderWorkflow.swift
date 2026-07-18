import Foundation
import PortavozCore

public protocol UpcomingMeetingListing: Sendable {
    func upcomingMeetings() async throws -> [UpcomingEvent]
}

public struct MeetingReminderRequest: Sendable {
    public let now: Date
    public let leadMinutes: Int
    public let alreadyReminded: Set<String>

    public init(
        now: Date,
        leadMinutes: Int,
        alreadyReminded: Set<String>
    ) {
        self.now = now
        self.leadMinutes = leadMinutes
        self.alreadyReminded = alreadyReminded
    }
}

public struct MeetingReminderNotice: Equatable, Sendable {
    public let event: UpcomingEvent
    public let minutesUntilStart: Int

    public init(event: UpcomingEvent, minutesUntilStart: Int) {
        self.event = event
        self.minutesUntilStart = max(1, minutesUntilStart)
    }
}

/// Resolves one session-deduplicated reminder from an injected calendar
/// projection. EventKit, preferences, clocks, panels, and localized copy stay
/// outside this workflow.
public struct ResolveMeetingReminder: ApplicationUseCase {
    private let meetings: any UpcomingMeetingListing

    public init(meetings: any UpcomingMeetingListing) {
        self.meetings = meetings
    }

    public func execute(
        _ request: MeetingReminderRequest
    ) async throws -> MeetingReminderNotice? {
        guard request.leadMinutes > 0 else { return nil }
        let events = try await meetings.upcomingMeetings()
        guard let event = ReminderPolicy.dueEvent(
            events: events,
            now: request.now,
            leadMinutes: request.leadMinutes,
            alreadyReminded: request.alreadyReminded
        ) else { return nil }
        let minutes = Int(
            (event.startDate.timeIntervalSince(request.now) / 60).rounded(.up))
        return MeetingReminderNotice(
            event: event,
            minutesUntilStart: minutes)
    }
}
