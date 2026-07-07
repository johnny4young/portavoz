import Foundation
import PortavozCore

/// Assigns speaker turns to audio. Implementations planned: pyannote
/// community-1 via FluidAudio (CoreML/ANE), with Sortformer as an
/// alternative. Runs on the `.system`/`.room` channels; the `.microphone`
/// channel is attributed to the user by hardware truth, no ML needed.
public protocol Diarizer: Sendable {
    func diarize(
        _ audio: AsyncStream<AudioChunk>
    ) -> AsyncThrowingStream<SpeakerTurn, Error>
}

/// A contiguous stretch of speech attributed to one (still unnamed) voice.
public struct SpeakerTurn: Codable, Sendable {
    /// Stable within a session: "S1", "S2"... mapped to `Speaker` records later.
    public let voiceLabel: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Double?

    public init(voiceLabel: String, startTime: TimeInterval, endTime: TimeInterval, confidence: Double? = nil) {
        self.voiceLabel = voiceLabel
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

/// The user's enrolled voice embedding. Biometric-grade data: stays
/// on-device, encrypted, never synced, deletable in one action.
public struct Voiceprint: Codable, Sendable {
    public let embedding: [Float]
    public let createdAt: Date

    public init(embedding: [Float], createdAt: Date = Date()) {
        self.embedding = embedding
        self.createdAt = createdAt
    }
}
