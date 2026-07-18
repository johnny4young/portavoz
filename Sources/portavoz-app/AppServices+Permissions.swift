import IntegrationsKit
import PlatformKit

extension AppServices {
    var microphonePermissionGranted: Bool {
        microphonePermissions.state() == .authorized
    }

    func requestMicrophonePermission() async -> Bool {
        await microphonePermissions.request()
    }

    func requestOnboardingCalendarAccess() async -> Bool {
        await CalendarAttendeeSource.requestAccess()
    }
}
