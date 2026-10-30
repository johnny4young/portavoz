import ApplicationKit
import os

/// Distances only, never names or speaker labels (D76): enough to tune the
/// match thresholds from Console without exporting who was recognized.
enum VoiceSuggestionLog {
    private static let logger = Logger(subsystem: "app.portavoz.mac", category: "voice-suggestions")

    static func shown(_ suggestions: [MeetingVoiceSuggestion]) {
        for suggestion in suggestions {
            logger.info(
                "shown distance=\(suggestion.distance, format: .fixed(precision: 3), privacy: .public) runnerUp=\(suggestion.runnerUpDistance ?? -1, format: .fixed(precision: 3), privacy: .public)")
        }
    }

    static func accepted(_ suggestion: MeetingVoiceSuggestion) {
        logger.info(
            "accepted distance=\(suggestion.distance, format: .fixed(precision: 3), privacy: .public) runnerUp=\(suggestion.runnerUpDistance ?? -1, format: .fixed(precision: 3), privacy: .public)")
    }
}
