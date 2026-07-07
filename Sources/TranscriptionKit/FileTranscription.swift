import Foundation
import PortavozCore

/// The result of transcribing a whole audio file — shared by every batch
/// engine (Parakeet for speed, Whisper for the final quality pass).
public struct FileTranscription: Sendable {
    public let text: String
    public let segments: [TranscriptSegment]
    public let audioDuration: TimeInterval
    public let processingTime: TimeInterval

    public init(
        text: String,
        segments: [TranscriptSegment],
        audioDuration: TimeInterval,
        processingTime: TimeInterval
    ) {
        self.text = text
        self.segments = segments
        self.audioDuration = audioDuration
        self.processingTime = processingTime
    }

    /// How many times faster than real time (higher is faster).
    public var speedFactor: Double {
        processingTime > 0 ? audioDuration / processingTime : 0
    }
}
