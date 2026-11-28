import AppKit
import ApplicationKit
import Foundation
import IntegrationsKit
import PortavozCore

extension AppServices {
    func startFloatingRecordPrompts() {
        guard !usesTemporaryMeetingStore else { return }
        meetingReminder.start(services: self)
        activeCallNudge.start(services: self)
    }

    /// Routes a floating prompt's Record click, reopening the library window
    /// when it was closed.
    func presentRecording(for event: UpcomingEvent?) {
        pendingRoute = .recording(event)
        if let openMainWindow = palette.openMainWindow {
            openMainWindow()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

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
