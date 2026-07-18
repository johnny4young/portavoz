import ApplicationKit
import Foundation
import IntegrationsKit
import PortavozCore

extension AppServices {
    func nextMeetingReminder(
        alreadyReminded: Set<String>
    ) async -> MeetingReminderNotice? {
        let lead = UserDefaults.standard.object(
            forKey: "meetingReminderMinutes") as? Int ?? 5
        return try? await ResolveMeetingReminder(
            meetings: AppUpcomingMeetingListing()
        ).execute(MeetingReminderRequest(
            now: Date(),
            leadMinutes: lead,
            alreadyReminded: alreadyReminded))
    }
}

private struct AppUpcomingMeetingListing: UpcomingMeetingListing {
    func upcomingMeetings() async throws -> [UpcomingEvent] {
        await Task.detached(priority: .utility) {
            CalendarAttendeeSource().upcomingEvents()
        }.value
    }
}
