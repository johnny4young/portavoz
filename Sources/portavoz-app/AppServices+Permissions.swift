import IntegrationsKit
import PlatformKit

extension AppServices {
    var microphonePermissionGranted: Bool {
        microphonePermissions.state() == .authorized
    }

    func requestMicrophonePermission() async -> Bool {
        await microphonePermissions.request()
    }

    /// Recording may prompt only from its explicit user action, before any
    /// AVAudioEngine input access can enter Core Audio.
    func authorizeMicrophoneForRecording() async -> Bool {
        await microphonePermissions.authorizeIfNeeded()
    }

    func requestOnboardingCalendarAccess() async -> Bool {
        await CalendarAttendeeSource.requestAccess()
    }
}
