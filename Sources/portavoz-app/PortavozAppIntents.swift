import AppIntents
import Foundation

/// Native App Intents let Shortcuts, Spotlight, and Siri drive Portavoz
/// without the URL-scheme detour. `portavoz://record` remains supported as a
/// separate adapter for external automation tools.
struct StartRecordingIntent: AppIntent {
    // Reuses the app's existing catalog key so Shortcuts shows the same
    // localized label as the in-app record control on every locale.
    static let title: LocalizedStringResource = "Start recording"
    static let description = IntentDescription(
        "Starts a new Portavoz meeting recording.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // openAppWhenRun foregrounds the exact bundle that owns this intent.
        // Route inside that process instead of asking LaunchServices to choose
        // among every installed app that handles the public URL scheme.
        PortavozAppIntentBridge.requestStartRecording()
        return .result()
    }
}

/// SDK-only process handoff shared by the intent and the app delegate.
///
/// App Intents metadata extraction compiles this file by itself, so the
/// bridge deliberately depends only on Foundation. The pending bit closes the
/// cold-launch race where `perform()` arrives before the delegate subscribes.
@MainActor
enum PortavozAppIntentBridge {
    static let startRecordingRequested = Notification.Name(
        "app.portavoz.start-recording-intent")

    private static var hasPendingStartRecording = false

    static func requestStartRecording() {
        hasPendingStartRecording = true
        notifyPendingStartRecordingRequest()
    }

    static func notifyPendingStartRecordingRequest() {
        guard hasPendingStartRecording else { return }
        NotificationCenter.default.post(
            name: startRecordingRequested,
            object: nil)
    }

    @discardableResult
    static func consumeStartRecordingRequest() -> Bool {
        let pending = hasPendingStartRecording
        hasPendingStartRecording = false
        return pending
    }
}
