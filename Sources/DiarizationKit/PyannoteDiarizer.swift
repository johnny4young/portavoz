import FluidAudio
import Foundation
import ModelStoreKit
import PortavozCore

// A type named `FluidAudio` inside the module shadows module
// qualification; the scoped import wins name resolution for `Speaker`
// in this file (our domain Speaker is not used here).
import struct FluidAudio.Speaker

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

    /// The reserved speaker id an enrolled voiceprint matches to; its
    /// turns come out labeled "Me" (isMe in attribution). This is what
    /// identifies the user in the system/room channel — hybrid meetings
    /// where their voice arrives through a room mic, not their own.
    static let enrolledSpeakerID = "me"
    public static let enrolledLabel = "Me"

    /// Loads from a directory the `ModelStore` verified. Uses FluidAudio's
    /// explicit-paths loader, which never falls back to downloading.
    public static func load(
        fromVerifiedDirectory directory: URL,
        clusteringThreshold: Float = defaultClusteringThreshold,
        voiceprint: Voiceprint? = nil
    ) throws -> PyannoteDiarizer {
        let models = try DiarizerModels.load(
            localSegmentationModel: directory.appendingPathComponent("pyannote_segmentation.mlmodelc"),
            localEmbeddingModel: directory.appendingPathComponent("wespeaker_v2.mlmodelc")
        )
        return PyannoteDiarizer(
            models: models, clusteringThreshold: clusteringThreshold, voiceprint: voiceprint)
    }

    /// Ensures the catalog model is downloaded + verified, then loads it.
    public static func loadRecommended(
        store: ModelStore,
        clusteringThreshold: Float = defaultClusteringThreshold,
        voiceprint: Voiceprint? = nil,
        progress: (@Sendable (ModelStore.DownloadProgress) -> Void)? = nil
    ) async throws -> PyannoteDiarizer {
        let descriptor = ModelCatalog.speakerDiarization
        let directory = try await store.ensureAvailable(descriptor, progress: progress)
        return try load(
            fromVerifiedDirectory: directory, clusteringThreshold: clusteringThreshold,
            voiceprint: voiceprint)
    }

    init(
        models: consuming DiarizerModels,
        clusteringThreshold: Float = defaultClusteringThreshold,
        voiceprint: Voiceprint? = nil
    ) {
        var config = DiarizerConfig.default
        config.clusteringThreshold = clusteringThreshold
        let manager = DiarizerManager(config: config)
        manager.initialize(models: models)
        if let voiceprint {
            manager.initializeKnownSpeakers([
                Speaker(
                    id: Self.enrolledSpeakerID,
                    name: Self.enrolledLabel,
                    currentEmbedding: voiceprint.embedding,
                    isPermanent: true)
            ])
        }
        self.manager = manager
    }

    // MARK: - Enrollment

    /// Builds a `Voiceprint` from a recording of the user speaking alone
    /// (≥ 5 s recommended). The embedding is all that leaves this call —
    /// the audio itself is the caller's to discard.
    public func extractVoiceprint(fromFile url: URL) throws -> Voiceprint {
        let samples = try converter.resampleAudioFile(url)
        return Voiceprint(embedding: try manager.extractSpeakerEmbedding(from: samples))
    }

    /// Same, from live-captured samples (the in-app enrollment path).
    public func extractVoiceprint(fromSamples samples: [Float], sampleRate: Double) throws -> Voiceprint {
        let resampled =
            sampleRate == Double(Self.modelSampleRate)
            ? samples
            : try converter.resample(samples, from: sampleRate)
        return Voiceprint(embedding: try manager.extractSpeakerEmbedding(from: resampled))
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
        let duration = Double(samples.count) / Double(Self.modelSampleRate)
        return Self.mergeMicroClusters(
            Self.sanitizeTurns(result.segments.map(Self.turn(from:)), audioDuration: duration))
    }

    /// Drops phantom speakers born in the last, zero-padded window: the
    /// padding dilutes that window's embedding, which routinely spawns a
    /// brand-new low-quality label for a voice that already has one
    /// (observed on every TTS fixture as a trailing "S3", q ≈ 0.2). A
    /// label is phantom only when ALL its turns start inside the final
    /// window AND its best quality stays low — a real latecomer with a
    /// clear voice survives, and "Me" (voiceprint) is never touched.
    /// Their audio becomes unattributed, which is the honest state.
    static func sanitizeTurns(
        _ turns: [SpeakerTurn],
        audioDuration: TimeInterval,
        qualityFloor: Double = 0.35
    ) -> [SpeakerTurn] {
        let tailStart = max(0, audioDuration - windowSeconds)
        let byLabel = Dictionary(grouping: turns, by: \.voiceLabel)
        let phantoms = byLabel.filter { label, turns in
            label != enrolledLabel
                && turns.allSatisfy { $0.startTime >= tailStart }
                && (turns.compactMap(\.confidence).max() ?? 0) < qualityFloor
        }.keys
        guard !phantoms.isEmpty else { return turns }
        return turns.filter { !phantoms.contains($0.voiceLabel) }
    }

    /// Real remote meetings fragment: per-participant codecs and mics push
    /// within-speaker embedding variance just past the assignment threshold,
    /// spawning micro-clusters (observed: 11 labels where ~4 people spoke,
    /// 6 of them carrying 3–28 s of a 1119 s meeting). The threshold itself
    /// can't move — 0.05 higher already merges AMI's two real speakers — so
    /// tiny labels get re-assigned instead: every turn of a label whose
    /// total speech stays under `minSpeechSeconds` moves to the temporally
    /// nearest turn of a major label. "Me" is identity (voiceprint-verified),
    /// so it is never merged away and never absorbs anyone; with no major
    /// label to inherit the turns, they stay as they are — a short meeting
    /// of short speakers is not fragmentation.
    static func mergeMicroClusters(
        _ turns: [SpeakerTurn],
        minSpeechSeconds: TimeInterval = 15
    ) -> [SpeakerTurn] {
        func totalSpeech(_ turns: [SpeakerTurn]) -> TimeInterval {
            turns.reduce(0) { $0 + ($1.endTime - $1.startTime) }
        }
        let byLabel = Dictionary(grouping: turns, by: \.voiceLabel)
        let protected = Set(
            byLabel.filter {
                $0.key == enrolledLabel || totalSpeech($0.value) >= minSpeechSeconds
            }.keys)
        guard protected.count < byLabel.count else { return turns }
        let targets = turns.filter {
            protected.contains($0.voiceLabel) && $0.voiceLabel != enrolledLabel
        }
        guard !targets.isEmpty else { return turns }

        return turns.map { turn in
            guard !protected.contains(turn.voiceLabel) else { return turn }
            let middle = (turn.startTime + turn.endTime) / 2
            guard
                let nearest = targets.min(by: {
                    Self.distance(from: middle, to: $0) < Self.distance(from: middle, to: $1)
                })
            else { return turn }
            return SpeakerTurn(
                voiceLabel: nearest.voiceLabel,
                startTime: turn.startTime,
                endTime: turn.endTime,
                confidence: turn.confidence
            )
        }
    }

    private static func distance(from point: TimeInterval, to turn: SpeakerTurn) -> TimeInterval {
        if point < turn.startTime { return turn.startTime - point }
        if point > turn.endTime { return point - turn.endTime }
        return 0
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
    /// "S1", "S2", … The enrolled voiceprint's reserved id maps to "Me".
    static func turn(from segment: TimedSpeakerSegment) -> SpeakerTurn {
        SpeakerTurn(
            voiceLabel: segment.speakerId == enrolledSpeakerID
                ? enrolledLabel : "S\(segment.speakerId)",
            startTime: TimeInterval(segment.startTimeSeconds),
            endTime: TimeInterval(segment.endTimeSeconds),
            confidence: Double(segment.qualityScore)
        )
    }
}
