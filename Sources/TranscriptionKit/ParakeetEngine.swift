import AVFoundation
import FluidAudio
import Foundation
import ModelStoreKit
import PortavozCore

/// Parakeet TDT 0.6B v3 (FluidAudio, CoreML/ANE): the default engine for
/// both live and final transcription in M2.
///
/// Live path: FluidAudio's `SlidingWindowAsrManager` with a short-chunk
/// window layout (see `liveWindowConfig`) — its stock `.streaming` config
/// only emits one update per 11 s chunk, far over the 2 s latency budget.
/// Batch path: `AsrManager`'s long-form pipeline (disk-backed over ~30 s),
/// tuned to be polite to a concurrent live job.
///
/// The class is stateless after init (models are immutable); every job
/// gets its own FluidAudio manager, so concurrent jobs never share decoder
/// state — only the loaded CoreML models (MLModel prediction is
/// thread-safe).
public final class ParakeetEngine: TranscriptionEngine, Sendable {
    public let descriptor: EngineDescriptor
    private let models: AsrModels

    /// Loads the engine from a directory the `ModelStore` has verified.
    /// Never point this at an unverified download — model files are code.
    public static func load(fromVerifiedDirectory directory: URL) async throws -> ParakeetEngine {
        let models = try await AsrModels.load(from: directory, version: .v3, encoderPrecision: .int8)
        return ParakeetEngine(models: models)
    }

    /// Ensures the catalog model is downloaded + verified, then loads it.
    public static func loadRecommended(
        store: ModelStore,
        progress: (@Sendable (ModelStore.DownloadProgress) -> Void)? = nil
    ) async throws -> ParakeetEngine {
        guard let descriptor = ModelCatalog.recommended(for: .liveTranscription) else {
            throw ModelStore.ModelStoreError.notInstalled(missing: ["no recommended model"], corrupted: [])
        }
        let directory = try await store.ensureAvailable(descriptor, progress: progress)
        return try await load(fromVerifiedDirectory: directory)
    }

    init(models: AsrModels) {
        self.models = models
        self.descriptor = EngineDescriptor(
            id: "parakeet-tdt-0.6b-v3",
            displayName: "Parakeet TDT 0.6B v3",
            languages: [],  // multilingual (25 European languages incl. es/en)
            realTimeFactor: 0.01,
            runsOnDevice: true,
            approximateMemoryMB: 600
        )
    }

    // MARK: - Live streaming

    /// Sliding-window layout for live captions. The window must fit the
    /// model's fixed 15 s input: 11 (left) + 1.0 (chunk) + 0.4 (right) =
    /// 12.4 s. Worst-case structural latency is chunk + right = 1.4 s,
    /// leaving ~0.6 s of the 2 s budget for inference and scheduling
    /// (measured 2026-07-06 on M4 Max: worst-word p95 1.7 s with the batch
    /// slot busy). The long left context is what preserves accuracy with
    /// tiny chunks.
    static let liveWindowConfig = SlidingWindowAsrConfig(
        chunkSeconds: 1.0,
        hypothesisChunkSeconds: 1.0,
        leftContextSeconds: 11.0,
        rightContextSeconds: 0.4,
        minContextForConfirmation: 10.0,
        confirmationThreshold: 0.80
    )

    public func transcribe(
        _ audio: AsyncStream<AudioChunk>,
        hints: TranscriptionHints
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        let models = self.models
        return AsyncThrowingStream { continuation in
            let job = Task {
                let manager = SlidingWindowAsrManager(config: Self.liveWindowConfig)
                do {
                    try await manager.loadModels(models)
                    try await manager.startStreaming(source: .microphone)

                    let meetingID = hints.meetingID ?? MeetingID()
                    let channelHolder = ChannelHolder()
                    let updates = await manager.transcriptionUpdates

                    let consumer = Task {
                        var lastEndTime: TimeInterval = 0
                        for await update in updates {
                            let segment = ParakeetSegmentMapper.segment(
                                text: update.text,
                                isConfirmed: update.isConfirmed,
                                confidence: update.confidence,
                                tokenTimings: update.tokenTimings,
                                meetingID: meetingID,
                                channel: await channelHolder.current,
                                language: hints.language,
                                fallbackTime: lastEndTime
                            )
                            if let segment {
                                lastEndTime = segment.endTime
                                continuation.yield(segment)
                            }
                        }
                    }

                    for await chunk in audio {
                        try Task.checkCancellation()
                        await channelHolder.set(chunk.channel)
                        if let buffer = chunk.pcmBuffer() {
                            await manager.streamAudio(buffer)
                        }
                    }

                    // Drain: finish() processes the remaining audio (yielding
                    // its updates), cancel() closes the update stream so the
                    // consumer ends after the buffered updates are delivered.
                    _ = try await manager.finish()
                    await manager.cancel()
                    await consumer.value
                    await manager.cleanup()
                    continuation.finish()
                } catch {
                    await manager.cleanup()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in job.cancel() }
        }
    }

    // MARK: - Batch files

    /// Transcribes a whole file through the long-form batch pipeline.
    /// `parallelChunkConcurrency` stays at 1 on purpose: batch runs in the
    /// scheduler's batch slot and must not saturate the ANE while a live
    /// job holds the live slot (D7: lo vivo nunca espera a lo batch).
    public func transcribeFile(
        at url: URL,
        hints: TranscriptionHints = TranscriptionHints(),
        channel: AudioChannel = .system
    ) async throws -> FileTranscription {
        let config = ASRConfig(
            parallelChunkConcurrency: 1,
            // Recommended off for v3 multilingual long-form (FluidAudio #594).
            melChunkContext: false
        )
        let manager = AsrManager(config: config)
        try await manager.loadModels(models)

        let language = hints.language.flatMap { Language(rawValue: $0) }
        var decoderState = try TdtDecoderState()
        let started = Date()
        let result = try await manager.transcribe(url, decoderState: &decoderState, language: language)
        let processingTime = Date().timeIntervalSince(started)

        // The disk-backed long-form path reports duration 0; read the real
        // length from the file so speedFactor stays meaningful.
        var audioDuration = result.duration
        if audioDuration <= 0, let file = try? AVAudioFile(forReading: url) {
            audioDuration = Double(file.length) / file.processingFormat.sampleRate
        }

        let meetingID = hints.meetingID ?? MeetingID()
        let segments = ParakeetSegmentMapper.segments(
            fromBatchText: result.text,
            tokenTimings: result.tokenTimings ?? [],
            audioDuration: audioDuration,
            confidence: Double(result.confidence),
            meetingID: meetingID,
            channel: channel,
            language: hints.language
        )
        await manager.cleanup()

        return FileTranscription(
            text: result.text,
            segments: segments,
            audioDuration: audioDuration,
            processingTime: processingTime
        )
    }
}

/// Last-seen capture channel of a live job, shared between the feeding loop
/// and the update consumer. Chunks are fed before any update can exist, so
/// the consumer always observes a real value.
private actor ChannelHolder {
    private(set) var current: AudioChannel = .microphone
    func set(_ channel: AudioChannel) { current = channel }
}

extension AudioChunk {
    /// Mono Float32 PCM buffer at the chunk's native rate; FluidAudio
    /// resamples to 16 kHz internally.
    func pcmBuffer() -> AVAudioPCMBuffer? {
        guard
            !samples.isEmpty,
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let destination = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                if let baseAddress = source.baseAddress {
                    destination.update(from: baseAddress, count: samples.count)
                }
            }
        }
        return buffer
    }
}
