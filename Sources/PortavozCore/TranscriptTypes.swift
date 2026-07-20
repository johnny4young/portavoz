import Foundation

/// A segment of transcribed speech, attributed to a speaker and a channel.
/// The `speakerID` may be nil while diarization is still resolving; the
/// channel is always known at capture time.
public struct TranscriptSegment: Codable, Sendable, Identifiable {
    public let id: UUID
    public let meetingID: MeetingID
    public var speakerID: SpeakerID?
    public let channel: AudioChannel
    public var text: String
    /// BCP-47 language tag of the spoken text (e.g. "en", "es").
    public var language: String?
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public var confidence: Double?
    /// Whether this segment is a live partial (may still change) or final.
    public var isFinal: Bool

    public init(
        id: UUID = UUID(),
        meetingID: MeetingID,
        speakerID: SpeakerID? = nil,
        channel: AudioChannel,
        text: String,
        language: String? = nil,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double? = nil,
        isFinal: Bool = false
    ) {
        self.id = id
        self.meetingID = meetingID
        self.speakerID = speakerID
        self.channel = channel
        self.text = text
        self.language = language
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.isFinal = isFinal
    }
}

/// One observed participant in a meeting. `isMe` is resolved from the
/// microphone channel (hardware truth) or from the user's enrolled voiceprint.
/// `personID` is a separately confirmed cross-meeting identity; diarization,
/// calendar candidates, and voice matches never populate it automatically.
public struct Speaker: Codable, Sendable, Identifiable {
    public var id: SpeakerID
    public let meetingID: MeetingID
    /// Diarization label before a name is known (e.g. "Speaker 2").
    public var label: String
    /// Meeting-local human name, accepted from a suggestion or entered by the user.
    public var displayName: String?
    public var isMe: Bool
    public var personID: PersonID?

    public init(
        id: SpeakerID = SpeakerID(),
        meetingID: MeetingID,
        label: String,
        displayName: String? = nil,
        isMe: Bool = false,
        personID: PersonID? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.label = label
        self.displayName = displayName
        self.isMe = isMe
        self.personID = personID
    }
}
