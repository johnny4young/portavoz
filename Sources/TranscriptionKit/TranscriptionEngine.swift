import Foundation
import PortavozCore

/// A speech-to-text engine. Implementations planned: Parakeet (FluidAudio,
/// ANE), WhisperKit, Apple SpeechAnalyzer (macOS 26+), and remote
/// OpenAI-compatible endpoints. The task router picks an engine per job:
/// a fast one for the live transcript, a high-quality one for the final
/// post-meeting pass — never one global setting.
public protocol TranscriptionEngine: Sendable {
    var descriptor: EngineDescriptor { get }
    func transcribe(
        _ audio: AsyncStream<AudioChunk>,
        hints: TranscriptionHints
    ) -> AsyncThrowingStream<TranscriptSegment, Error>
}

/// Static capabilities of an engine, used by the router and the model picker UI.
public struct EngineDescriptor: Codable, Sendable {
    public let id: String
    public let displayName: String
    /// BCP-47 tags the engine supports; empty means "multilingual/auto".
    public let languages: [String]
    /// Approximate real-time factor (lower is faster; 0.01 ≈ 100× realtime).
    public let realTimeFactor: Double
    public let runsOnDevice: Bool
    public let approximateMemoryMB: Int

    public init(
        id: String,
        displayName: String,
        languages: [String] = [],
        realTimeFactor: Double,
        runsOnDevice: Bool,
        approximateMemoryMB: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.languages = languages
        self.realTimeFactor = realTimeFactor
        self.runsOnDevice = runsOnDevice
        self.approximateMemoryMB = approximateMemoryMB
    }
}

/// Per-job guidance for an engine.
public struct TranscriptionHints: Codable, Sendable {
    /// Expected language, if known ("en", "es"); nil = auto-detect.
    public var language: String?
    /// Domain vocabulary injected as an initial prompt so "Kubernetes"
    /// never becomes "communities": service names, teammate names, acronyms.
    public var vocabulary: [String]
    /// Meeting the emitted segments belong to; a fresh ID is generated per
    /// job when nil (dev CLI, ad-hoc file transcription).
    public var meetingID: MeetingID?

    public init(language: String? = nil, vocabulary: [String] = [], meetingID: MeetingID? = nil) {
        self.language = language
        self.vocabulary = vocabulary
        self.meetingID = meetingID
    }
}
