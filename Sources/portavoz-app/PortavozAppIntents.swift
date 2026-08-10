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
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]

    @MainActor
    func perform() async throws -> some IntentResult {
        // The foreground execution mode selects the exact bundle that owns
        // this intent. Route inside that process instead of asking
        // LaunchServices to choose among every installed URL handler.
        PortavozAppIntentBridge.requestStartRecording()
        return .result()
    }
}

/// Stops only the process-owned recording that is already active.
///
/// `perform()` reports that Portavoz accepted the request; it never claims
/// that capture was durably finalized before the recording controller finishes
/// its existing stop workflow. Every non-actionable state names one recovery.
struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop recording"
    static let description = IntentDescription(
        "Stops the current Portavoz meeting recording.")
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let disposition = PortavozAppIntentBridge.requestStopRecording()
        return .result(dialog: IntentDialog(disposition.dialog))
    }
}

// `IntentModes` starts at macOS 26. Keep the framework's documented
// compatibility property for Sequoia and older supported systems while the
// availability-gated declaration above supplies the modern Tahoe contract.
@available(*, deprecated)
extension StartRecordingIntent {
    static var openAppWhenRun: Bool { true }
}

@available(*, deprecated)
extension StopRecordingIntent {
    static var openAppWhenRun: Bool { true }
}

/// SDK-only process handoff shared by the intent and the app delegate.
///
/// App Intents metadata extraction compiles this file by itself, so the
/// bridge deliberately depends only on Foundation. The pending bit closes the
/// cold-launch race where `perform()` arrives before the delegate subscribes.
@MainActor
enum PortavozAppIntentBridge {
    enum StopRecordingRequestDisposition: Equatable {
        case queued
        case accepted
        case noActiveRecording
        case recordingIsPreparing
        case alreadyStopping
        case recoveryRequired

        var dialog: LocalizedStringResource {
            switch self {
            case .queued:
                "Portavoz will handle the stop request after it finishes opening."
            case .accepted:
                "Portavoz is stopping the current recording."
            case .noActiveRecording:
                "No recording is active. Use Start recording to begin one."
            case .recordingIsPreparing:
                "Portavoz is still starting the recording. Run Stop recording again when the live controls appear."
            case .alreadyStopping:
                "Portavoz is already stopping the recording. Open Portavoz to view progress."
            case .recoveryRequired:
                "The recording needs attention. Open Portavoz and use the recovery action shown."
            }
        }
    }

    static let startRecordingRequested = Notification.Name(
        "app.portavoz.start-recording-intent")
    static let stopRecordingRequested = Notification.Name(
        "app.portavoz.stop-recording-intent")

    private static var hasPendingStartRecording = false
    private static var hasPendingStopRecording = false
    private static var stopRecordingDisposition:
        StopRecordingRequestDisposition = .queued

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

    static func requestStopRecording() -> StopRecordingRequestDisposition {
        hasPendingStopRecording = true
        stopRecordingDisposition = .queued
        notifyPendingStopRecordingRequest()
        return stopRecordingDisposition
    }

    static func notifyPendingStopRecordingRequest() {
        guard hasPendingStopRecording else { return }
        NotificationCenter.default.post(
            name: stopRecordingRequested,
            object: nil)
    }

    @discardableResult
    static func consumeStartRecordingRequest() -> Bool {
        let pending = hasPendingStartRecording
        hasPendingStartRecording = false
        return pending
    }

    @discardableResult
    static func consumeStopRecordingRequest(
        as disposition: StopRecordingRequestDisposition
    ) -> Bool {
        guard hasPendingStopRecording else { return false }
        hasPendingStopRecording = false
        stopRecordingDisposition = disposition
        return true
    }
}
