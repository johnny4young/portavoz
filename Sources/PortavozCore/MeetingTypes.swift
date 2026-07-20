import Foundation

/// Durable aggregate lifecycle. Derived processing may fail without hiding
/// the captured meeting or its audio.
public enum MeetingLifecycleState: String, Codable, CaseIterable, Sendable {
    case recording
    case captured
    case processing
    case ready
    case needsAttention
}

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
    /// Persisted state of the durable recording/processing aggregate.
    public var lifecycleState: MeetingLifecycleState
    /// Zero is the original transcript; each accepted replacement increments it.
    public var transcriptRevision: Int
    /// Stable local error code for the last exhausted required processing step.
    public var lastProcessingError: String?

    public init(
        id: MeetingID = MeetingID(),
        title: String,
        startedAt: Date,
        endedAt: Date? = nil,
        language: String? = nil,
        audioDirectory: String? = nil,
        retention: AudioRetentionPolicy = .keep,
        visibility: String = "private",
        lifecycleState: MeetingLifecycleState = .ready,
        transcriptRevision: Int = 0,
        lastProcessingError: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.language = language
        self.audioDirectory = audioDirectory
        self.retention = retention
        self.visibility = visibility
        self.lifecycleState = lifecycleState
        self.transcriptRevision = transcriptRevision
        self.lastProcessingError = lastProcessingError
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, startedAt, endedAt, language, audioDirectory
        case retention, visibility, lifecycleState, transcriptRevision
        case lastProcessingError
    }

    /// Additive bundle compatibility: meetings exported before schema v6 do
    /// not carry lifecycle fields and represent completed (`ready`) meetings.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(MeetingID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        audioDirectory = try container.decodeIfPresent(String.self, forKey: .audioDirectory)
        retention = try container.decode(AudioRetentionPolicy.self, forKey: .retention)
        visibility = try container.decode(String.self, forKey: .visibility)
        lifecycleState = try container.decodeIfPresent(
            MeetingLifecycleState.self, forKey: .lifecycleState) ?? .ready
        transcriptRevision = try container.decodeIfPresent(
            Int.self, forKey: .transcriptRevision) ?? 0
        lastProcessingError = try container.decodeIfPresent(
            String.self, forKey: .lastProcessingError)
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
