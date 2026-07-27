import AppIntents
import AppKit
import Foundation

/// FEATURE-001: native App Intents so Shortcuts, Spotlight, and Siri can
/// drive Portavoz without the URL-scheme detour. The intents reuse the
/// existing app routes — `portavoz://record` remains supported for external
/// automation tools.
struct StartRecordingIntent: AppIntent {
    // Reuses the app's existing catalog key so Shortcuts shows the same
    // localized label as the in-app record control on every locale.
    static let title: LocalizedStringResource = "Start recording"
    static let description = IntentDescription(
        "Starts a new Portavoz meeting recording.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // The exact path external automation already exercises (M16): the
        // URL route owns focus, permissions, and the recording screen.
        guard let url = URL(string: "portavoz://record"),
              NSWorkspace.shared.open(url) else {
            throw StartRecordingIntentError.recordRouteFailed
        }
        return .result()
    }
}

/// Shortcuts/Siri report success from a clean `perform()` return, so a
/// failed route must throw — otherwise the automation claims a recording
/// started when nothing happened.
enum StartRecordingIntentError: Error, CustomLocalizedStringResourceConvertible {
    case recordRouteFailed

    var localizedStringResource: LocalizedStringResource {
        "Portavoz could not open the recording screen."
    }
}

/// The Shortcuts app surfaces these phrases; both locales ship because the
/// product is Spanish-first (D-series naming).
struct PortavozShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start a recording in \(.applicationName)",
                "Graba con \(.applicationName)"
            ],
            shortTitle: "Start recording",
            systemImageName: "record.circle")
    }
}
