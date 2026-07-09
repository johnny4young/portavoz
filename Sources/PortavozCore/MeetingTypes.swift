import Foundation

/// A recorded (or in-progress) meeting — the aggregate root everything
/// else hangs off: segments, speakers, summaries, audio files.
public struct Meeting: Codable, Sendable, Identifiable {
    public var id: MeetingID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    /// Meeting-wide language when homogeneous/known ("en", "es");
    /// nil = mixed/unknown.
    public var language: String?
    /// Directory holding the meeting's audio, RELATIVE to the app's audio
    /// root — the database never stores absolute paths (D4).
    public var audioDirectory: String?
    public var retention: AudioRetentionPolicy
    /// Reserved since v1 for the sharing ladder (D4/D12). Only "private"
    /// exists today.
    public var visibility: String

    public init(
        id: MeetingID = MeetingID(),
        title: String,
        startedAt: Date,
        endedAt: Date? = nil,
        language: String? = nil,
        audioDirectory: String? = nil,
        retention: AudioRetentionPolicy = .keep,
        visibility: String = "private"
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.language = language
        self.audioDirectory = audioDirectory
        self.retention = retention
        self.visibility = visibility
    }
}

/// What happens to raw audio files after a meeting — a first-class privacy
/// and disk-space control, configurable per meeting or globally.
public enum AudioRetentionPolicy: Codable, Sendable, Equatable {
    /// Keep the recording indefinitely.
    case keep
    /// Delete the audio N days after the meeting ends (transcript is kept).
    case deleteAfter(days: Int)
    /// Delete the audio as soon as transcription completes.
    case deleteAfterTranscription
}
