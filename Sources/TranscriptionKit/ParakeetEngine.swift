import AVFoundation
import FluidAudio
import Foundation
import ModelStoreKit
import PortavozCore

/// Verified Parakeet weights that share the v3 component contract.
public enum ParakeetCheckpoint: String, Sendable {
    case v3
    case ultra
}

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
    public let checkpoint: ParakeetCheckpoint
    typealias LiveManagerPreparation = @Sendable (SlidingWindowAsrConfig) async throws -> SlidingWindowAsrManager
    typealias BatchManagerPreparation = @Sendable (ASRConfig) async throws -> AsrManager

    private let prepareLiveManager: LiveManagerPreparation
    private let prepareBatchManager: BatchManagerPreparation
    private let liveWorkObserver: (@Sendable (ParakeetLiveWorkSample) -> Void)?

    /// Loads the engine from a directory the `ModelStore` has verified.
    /// Never point this at an unverified download — model files are code.
    @concurrent
    public static func load(
        fromVerifiedDirectory directory: URL, checkpoint: ParakeetCheckpoint = .v3
    ) async throws -> ParakeetEngine {
        try Task.checkCancellation()
        // The curated v3 graph has no optional CTC head. Do not let vendor
        // discovery expand the verified artifact set or trigger ModelHub.
        let optionalHead = directory.appendingPathComponent(ModelNames.ASR.ctcHeadFile)
        guard !FileManager.default.fileExists(atPath: optionalHead.path) else {
            throw VerifiedLoadFailure.unexpectedOptionalModel
        }
        let models = try AsrModels.loadLocal(
            from: directory, version: checkpoint == .ultra ? .ultra : .v3, encoderPrecision: .int8)
        try Task.checkCancellation()
        return ParakeetEngine(models: models, checkpoint: checkpoint)
    }

    enum VerifiedLoadFailure: Error {
        case unexpectedOptionalModel
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

    /// Shares verified immutable model weights while observing only public
    /// live-adapter counts. Batch jobs and the normal engine are unchanged.
    public func observingLiveWork(
        _ observer: @escaping @Sendable (ParakeetLiveWorkSample) -> Void
    ) -> ParakeetEngine {
        ParakeetEngine(
            prepareLiveManager: prepareLiveManager,
            prepareBatchManager: prepareBatchManager,
            liveWorkObserver: observer,
            checkpoint: checkpoint)
    }

    convenience init(
        models: AsrModels,
        liveWorkObserver: (@Sendable (ParakeetLiveWorkSample) -> Void)? = nil,
        checkpoint: ParakeetCheckpoint = .v3
    ) {
        self.init(
            prepareLiveManager: { config in
                let manager = SlidingWindowAsrManager(config: config)
                do {
                    try await manager.loadModels(models)
                    return manager
                } catch {
                    await manager.cleanup()
                    throw error
                }
            },
            prepareBatchManager: { config in
                let manager = AsrManager(config: config)
                do {
                    try await manager.loadModels(models)
                    return manager
                } catch {
                    await manager.cleanup()
                    throw error
                }
            },
            liveWorkObserver: liveWorkObserver,
            checkpoint: checkpoint)
    }

    /// Each preparation owns a fresh manager until its verified models are
    /// ready, then transfers cleanup to the job. The closures share only the
    /// immutable weights, never decoder state, between concurrent jobs.
    init(
        prepareLiveManager: @escaping LiveManagerPreparation,
        prepareBatchManager: @escaping BatchManagerPreparation,
        liveWorkObserver: (@Sendable (ParakeetLiveWorkSample) -> Void)? = nil,
        checkpoint: ParakeetCheckpoint = .v3
    ) {
        // Vendor debug messages contain hypotheses. Keep them out of stderr;
        // warnings/errors remain in the system log with default private text.
        AppLogger.mirrorsToConsole = false
        AppLogger.minimumLevel = .warning
        self.prepareLiveManager = prepareLiveManager
        self.prepareBatchManager = prepareBatchManager
        self.liveWorkObserver = liveWorkObserver
        self.checkpoint = checkpoint
        self.descriptor = EngineDescriptor(
            id: checkpoint == .ultra ? "parakeet-ultra" : "parakeet-tdt-0.6b-v3",
            displayName: checkpoint == .ultra ? "Parakeet Ultra" : "Parakeet TDT 0.6B v3",
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
        let prepareLiveManager = self.prepareLiveManager
        let observer = liveWorkObserver
        return AsyncThrowingStream { continuation in
            let job = Task {
                let probe = observer.map { _ in ParakeetLiveWorkProbe() }
                var preparedManager: SlidingWindowAsrManager?
                var consumer: Task<Void, Error>?
                let channelHolder = ParakeetStreamChannel()
                do {
                    // Parakeet's hint filters writing systems, not languages
                    // sharing an alphabet: Spanish and English remain multilingual.
                    let configuration = Self.liveWindowConfig.applying(
                        language: hints.filtersLiveScript == true ? Self.fluidLanguage(hints) : nil)
                    let manager = try await prepareLiveManager(configuration)
                    preparedManager = manager
                    try await manager.startStreaming(source: .microphone)
                    probe?.begin(.feed)

                    let updates = await manager.tokenUpdates
                    consumer = Task {
                        do {
                            try await Self.consume(
                                updates, hints: hints, channelHolder: channelHolder,
                                continuation: continuation, probe: probe)
                        } catch {
                            // Surface producer failure while capture is still feeding;
                            // output termination cancels this job and joins cleanup.
                            if !(error is CancellationError), !Task.isCancelled {
                                await channelHolder.markProducerFailure()
                            }
                            continuation.finish(throwing: error)
                            throw error
                        }
                    }

                    try await Self.feed(audio, manager: manager, channelHolder: channelHolder, probe: probe)

                    try Task.checkCancellation()

                    // Drain: finish() processes the remaining audio (yielding
                    // its updates), cancel() closes the update stream so the
                    // consumer ends after the buffered updates are delivered.
                    probe?.begin(.finish)
                    _ = try await manager.finish()
                    probe?.begin(.updateDrain)
                    await manager.cancel()
                    try await consumer?.value
                    try Task.checkCancellation()
                    probe?.begin(.cleanup)
                    await manager.cleanup()
                    if let sample = probe?.finish(outcome: Task.isCancelled ? .cancelled : .completed) {
                        observer?(sample)
                    }
                    continuation.finish()
                } catch {
                    probe?.begin(.cleanup)
                    await preparedManager?.cancel()
                    consumer?.cancel()
                    _ = try? await consumer?.value
                    await preparedManager?.cleanup()
                    let outcome = await channelHolder.outcome(for: error, cancelled: Task.isCancelled)
                    if let sample = probe?.finish(outcome: outcome) { observer?(sample) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in job.cancel() }
        }
    }

    private static func fluidLanguage(_ hints: TranscriptionHints) -> Language? {
        hints.language.flatMap { Language(rawValue: $0) }
    }

    static func consume(
        _ updates: AsyncThrowingStream<SlidingWindowTokenUpdate, Error>,
        hints: TranscriptionHints,
        channelHolder: ParakeetStreamChannel,
        continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation,
        probe: ParakeetLiveWorkProbe?
    ) async throws {
        let meetingID = hints.meetingID ?? MeetingID()
        var stream = ParakeetSegmentMapper.RevisionStream()
        do {
            for try await update in updates {
                try Task.checkCancellation()
                // Terminal is control metadata, not another native inference.
                if !update.revision.isTerminal {
                    probe?.update(tokens: update.tokens.count,
                                  timings: update.tokens.count, confirmed: update.isConfirmed)
                }
                let channel = await channelHolder.current
                guard channel != nil || (update.revision.isTerminal && update.tokens.isEmpty
                    && update.revision.previousTokenCount == 0) else {
                    throw ParakeetStreamChannel.Failure.unboundChannel
                }
                // An empty job still validates terminal lineage, but owns no
                // capture channel and cannot publish a cross-job preview clear.
                let segments = try stream.segments(
                    from: update, meetingID: meetingID,
                    channel: channel ?? .microphone, language: hints.language)
                if channel != nil {
                    for segment in segments { continuation.yield(segment) }
                }
            }
            try stream.finish()
        } catch {
            if !Task.isCancelled, let channel = await channelHolder.current {
                continuation.yield(TranscriptSegment(
                    meetingID: meetingID, channel: channel,
                    text: "", language: hints.language, startTime: 0, endTime: 0,
                    isFinal: false, liveUpdateMode: .tokenPreview))
            }
            throw error
        }
    }

    static func feed(
        _ audio: AsyncStream<AudioChunk>,
        manager: SlidingWindowAsrManager,
        channelHolder: ParakeetStreamChannel,
        probe: ParakeetLiveWorkProbe?
    ) async throws {
        for await chunk in audio {
            try Task.checkCancellation()
            // Empty callbacks carry no PCM and cannot bind a capture channel.
            guard !chunk.samples.isEmpty else { continue }
            if let buffer = chunk.pcmBuffer() {
                try await channelHolder.set(chunk.channel)
                probe?.input(frames: chunk.samples.count, sampleRate: chunk.sampleRate,
                             channel: chunk.channel, accepted: true)
                await manager.streamAudio(buffer)
            } else {
                probe?.input(frames: chunk.samples.count, sampleRate: chunk.sampleRate,
                             channel: chunk.channel, accepted: false)
                throw ParakeetStreamChannel.Failure.invalidAudioChunk
            }
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
        let manager = try await prepareBatchManager(config)

        let language = Self.fluidLanguage(hints)
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

/// Single capture channel of a live job, shared between the feeding loop
/// and the update consumer. Inference follows admitted PCM; terminal/error
/// metadata may exist without PCM and has no capture-channel authority.
actor ParakeetStreamChannel {
    enum Failure: Error { case mixedChannels, invalidAudioChunk, unboundChannel }
    private var bound: AudioChannel?
    private var producerFailed = false

    func markProducerFailure() { producerFailed = true }

    func outcome(for error: Error, cancelled: Bool) -> ParakeetLiveWorkSample.Outcome {
        if producerFailed { return .failed }
        return error is CancellationError || cancelled ? .cancelled : .failed
    }

    var current: AudioChannel? { bound }

    func set(_ channel: AudioChannel) throws {
        guard bound == nil || bound == channel else { throw Failure.mixedChannels }
        bound = channel
    }
}

extension AudioChunk {
    /// Mono Float32 PCM buffer at the chunk's native rate; FluidAudio
    /// resamples to 16 kHz internally.
    func pcmBuffer() -> AVAudioPCMBuffer? {
        guard
            !samples.isEmpty, samples.count <= Int(AVAudioFrameCount.max),
            sampleRate.isFinite, sampleRate > 0,
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let destination = buffer.floatChannelData?[0] else { return nil }
        // A device glitch becomes brief silence; keeping the sample count keeps
        // producer positions aligned instead of ending the live session.
        for (index, sample) in samples.enumerated() {
            destination[index] = sample.isFinite ? sample : 0
        }
        return buffer
    }
}
