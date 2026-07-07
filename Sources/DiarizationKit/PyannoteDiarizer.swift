import FluidAudio
import Foundation
import ModelStoreKit
import PortavozCore

/// pyannote community-1 segmentation + WeSpeaker v2 embeddings via
/// FluidAudio (CoreML/ANE) — the M3 diarizer for the `.system`/`.room`
/// channels. The `.microphone` channel never goes through this: it is the
/// user by hardware truth (D5).
///
/// One instance = one session: FluidAudio's `SpeakerManager` accumulates
/// the voice database across calls, which is exactly what keeps "S1" stable
/// from the first window to the last — but it means turns from different
/// meetings must not share an instance.
public actor PyannoteDiarizer: Diarizer {
    /// Streaming window fed to the model. Matches FluidAudio's internal
    /// chunk duration; speaker continuity across windows comes from the
    /// shared `SpeakerManager`, not from window overlap.
    static let windowSeconds: TimeInterval = 10
    static let modelSampleRate = 16_000

    /// FluidAudio's `.default` (0.7) multiplies out to a 0.84 cosine-
    /// distance assignment threshold (`speakerThreshold = clustering ×
    /// 1.2`) — permissive enough that it merged the two speakers of
    /// pyannote's AMI reference sample into one, and 0.55 still did.
    /// 0.45 (→ 0.54 assignment) reproduces the AMI reference RTTM almost
    /// exactly and separates two-voice TTS fixtures correctly (calibrated
    /// 2026-07-07). Revisit with the M3 acceptance meeting (real 4 people,
    /// DER < 15%): if it over-splits there, the knob is per-call.
    public static let defaultClusteringThreshold: Float = 0.45

    private let manager: DiarizerManager
    private let converter = AudioConverter()

    /// Loads from a directory the `ModelStore` verified. Uses FluidAudio's
    /// explicit-paths loader, which never falls back to downloading.
    public static func load(
        fromVerifiedDirectory directory: URL,
        clusteringThreshold: Float = defaultClusteringThreshold
    ) throws -> PyannoteDiarizer {
        let models = try DiarizerModels.load(
            localSegmentationModel: directory.appendingPathComponent("pyannote_segmentation.mlmodelc"),
            localEmbeddingModel: directory.appendingPathComponent("wespeaker_v2.mlmodelc")
        )
        return PyannoteDiarizer(models: models, clusteringThreshold: clusteringThreshold)
    }

    /// Ensures the catalog model is downloaded + verified, then loads it.
    public static func loadRecommended(
        store: ModelStore,
        clusteringThreshold: Float = defaultClusteringThreshold,
        progress: (@Sendable (ModelStore.DownloadProgress) -> Void)? = nil
    ) async throws -> PyannoteDiarizer {
        let descriptor = ModelCatalog.speakerDiarization
        let directory = try await store.ensureAvailable(descriptor, progress: progress)
        return try load(fromVerifiedDirectory: directory, clusteringThreshold: clusteringThreshold)
    }

    init(models: consuming DiarizerModels, clusteringThreshold: Float = defaultClusteringThreshold) {
        var config = DiarizerConfig.default
        config.clusteringThreshold = clusteringThreshold
        let manager = DiarizerManager(config: config)
        manager.initialize(models: models)
        self.manager = manager
    }

    // MARK: - Diarizer

    public nonisolated func diarize(
        _ audio: AsyncStream<AudioChunk>
    ) -> AsyncThrowingStream<SpeakerTurn, Error> {
        AsyncThrowingStream { continuation in
            let job = Task {
                do {
                    let windowSamples = Int(Self.windowSeconds) * Self.modelSampleRate
                    var buffer: [Float] = []
                    var windowStart: TimeInterval = 0

                    for await chunk in audio {
                        try Task.checkCancellation()
                        buffer.append(contentsOf: try await self.resample(chunk))
                        while buffer.count >= windowSamples {
                            let window = Array(buffer.prefix(windowSamples))
                            buffer.removeFirst(windowSamples)
                            let turns = try await self.processWindow(window, at: windowStart)
                            windowStart += Self.windowSeconds
                            for turn in turns { continuation.yield(turn) }
                        }
                    }

                    // Tail shorter than a window (the model zero-pads); skip
                    // fragments under the 1 s minimum speech duration.
                    if buffer.count >= Self.modelSampleRate {
                        let turns = try await self.processWindow(buffer, at: windowStart)
                        for turn in turns { continuation.yield(turn) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in job.cancel() }
        }
    }

    /// Batch: diarizes a whole file in one pass (FluidAudio chunks it
    /// internally at the same window size, tracking speakers throughout).
    public func diarizeFile(at url: URL) throws -> [SpeakerTurn] {
        let samples = try converter.resampleAudioFile(url)
        let result = try manager.performCompleteDiarization(
            samples, sampleRate: Self.modelSampleRate)
        return result.segments.map(Self.turn(from:))
    }

    // MARK: - Internals

    private func resample(_ chunk: AudioChunk) throws -> [Float] {
        guard chunk.sampleRate != Double(Self.modelSampleRate) else { return chunk.samples }
        return try converter.resample(chunk.samples, from: chunk.sampleRate)
    }

    private func processWindow(_ samples: [Float], at offset: TimeInterval) throws -> [SpeakerTurn] {
        let result = try manager.performCompleteDiarization(
            samples, sampleRate: Self.modelSampleRate, atTime: offset)
        return result.segments.map(Self.turn(from:))
    }

    /// FluidAudio labels speakers "1", "2", … — our domain labels are
    /// "S1", "S2", … (mapped to named `Speaker` records later).
    static func turn(from segment: TimedSpeakerSegment) -> SpeakerTurn {
        SpeakerTurn(
            voiceLabel: "S\(segment.speakerId)",
            startTime: TimeInterval(segment.startTimeSeconds),
            endTime: TimeInterval(segment.endTimeSeconds),
            confidence: Double(segment.qualityScore)
        )
    }
}
