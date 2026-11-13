import Foundation

/// This is a live-lane choice, not a replacement for the durable batch model.
/// Meetings default to Parakeet v3.
enum LiveSpeechSelection: String, CaseIterable {
    case parakeet
    case appleSpeech

    static let meetingKey = "meetingLiveSpeechEngine"

    /// A value no meeting lane reads, such as 1.x's dictation-only Ultra, falls back to v3.
    static func meeting(defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: meetingKey) ?? "") ?? .parakeet
    }
}
