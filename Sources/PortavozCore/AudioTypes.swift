import Foundation

/// Where an audio stream originates. Portavoz records channels *separately*
/// and never mixes them before diarization: everything on `.microphone` is
/// the user by definition, which is what makes "which interventions were
/// mine" nearly free.
public enum AudioChannel: String, Codable, Sendable, CaseIterable {
    /// The local user's microphone.
    case microphone
    /// Remote participants, captured via a per-app Core Audio process tap (macOS).
    case system
    /// A room microphone in hybrid meetings (e.g. an iPhone via Continuity).
    case room
}

/// A chunk of PCM audio flowing through the capture pipeline.
public struct AudioChunk: Sendable {
    public let channel: AudioChannel
    public let samples: [Float]
    public let sampleRate: Double
    /// Seconds since the recording session started.
    public let timestamp: TimeInterval

    public init(channel: AudioChannel, samples: [Float], sampleRate: Double, timestamp: TimeInterval) {
        self.channel = channel
        self.samples = samples
        self.sampleRate = sampleRate
        self.timestamp = timestamp
    }

    public var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }
}
