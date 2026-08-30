import ApplicationKit
import AudioCaptureKit
import DiarizationKit
import Foundation
import PortavozCore
import TranscriptionKit

/// Exact hidden admission for the public, autonomous recording resource input.
/// A temporary store alone is intentionally insufficient: production and
/// ordinary development recording continue to use real TCC-gated capture.
enum BenchSyntheticCapturePolicy {
    static let option = "--bench-resource-synthetic-capture"
    static let generation = "public-synthetic-dual-channel-v2"
    static let sampleRate = 16_000.0
    static let chunkFrames = 1_600

    static func expectedFrames(durationSeconds: Int) -> Int64? {
        guard (30...600).contains(durationSeconds) else { return nil }
        return Int64(durationSeconds) * Int64(sampleRate)
    }

    static func hasExactFrames(
        _ frames: [AudioChannel: Int64],
        expectedFrames: Int64
    ) -> Bool {
        frames.count == 2
            && frames[.microphone] == expectedFrames
            && frames[.system] == expectedFrames
    }

    static func requested(arguments: [String]) -> Bool {
        appearsOnce(option, in: arguments)
            && appearsOnce("-use-temp-store", in: arguments)
            && appearsOnce("--bench-record", in: arguments)
            && appearsOnce("--bench-resource-output", in: arguments)
    }

    static func validateResourceRequest(arguments: [String]) throws -> Bool {
        let ownsResourceOutput = arguments.contains("--bench-record")
            && arguments.contains("--bench-resource-output")
        guard ownsResourceOutput else {
            guard !arguments.contains(option) else {
                throw BenchSyntheticCaptureError.invalidAdmission
            }
            return false
        }
        guard requested(arguments: arguments) else {
            throw BenchSyntheticCaptureError.syntheticInputRequired
        }
        return true
    }

    private static func appearsOnce(
        _ option: String,
        in arguments: [String]
    ) -> Bool {
        arguments.lazy.filter { $0 == option }.prefix(2).count == 1
    }
}

@MainActor
final class BenchSyntheticStartRecordingRuntime: StartRecordingRuntime {
    private struct Prepared {
        let sources: [BenchSyntheticAudioCaptureSource]
        let liveTranscriptionRuntime: LiveTranscriptionRuntime?
    }

    private weak var services: AppServices?
    private let audioRoot: URL
    private let expectedFrames: Int64?
    private var prepared: Prepared?

    init(
        services: AppServices,
        audioRoot: URL,
        durationSeconds: Int
    ) {
        self.services = services
        self.audioRoot = audioRoot
        expectedFrames = BenchSyntheticCapturePolicy.expectedFrames(
            durationSeconds: durationSeconds)
    }

    func prepare(
        preferences: StartRecordingPreferencesSnapshot
    ) async throws -> StartRecordingPreparedRuntime {
        guard let services, let expectedFrames else {
            throw StartRecordingRuntimeError.preparationUnavailable
        }
        let liveSpeech = try services.acquireResidentLiveSpeechRuntime()
        let liveTranscriptionRuntime = liveSpeech.map {
            services.liveTranscriptionRuntime($0)
        }
        guard
            let microphone = BenchSyntheticAudioCaptureSource(
                channel: .microphone,
                expectedFrames: expectedFrames),
            let system = BenchSyntheticAudioCaptureSource(
                channel: .system,
                expectedFrames: expectedFrames)
        else {
            throw StartRecordingRuntimeError.preparationUnavailable
        }
        let sources = [microphone, system]
        prepared = Prepared(
            sources: sources,
            liveTranscriptionRuntime: liveTranscriptionRuntime)
        return StartRecordingPreparedRuntime(
            channels: sources.map(\.channel),
            liveTranscriptionAvailable: liveTranscriptionRuntime != nil)
    }

    func startCapture(
        _ request: StartRecordingCaptureRequest
    ) async throws -> any StartRecordingSession {
        guard let prepared, let services, let expectedFrames else {
            throw StartRecordingRuntimeError.preparationUnavailable
        }
        self.prepared = nil
        let active = BenchSyntheticStartRecordingSession(
            outputDirectory: audioRoot.appendingPathComponent(
                request.audioDirectory),
            sources: prepared.sources,
            expectedFrames: expectedFrames,
            liveTranscriptionRuntime: prepared.liveTranscriptionRuntime,
            transcriberLoader: { @MainActor [weak services] in
                guard let services else {
                    throw StartRecordingRuntimeError.preparationUnavailable
                }
                let runtime = try await services.acquireLiveSpeechRuntime()
                return services.liveTranscriptionRuntime(runtime)
            },
            telemetry: services.workloadTelemetry)
        do {
            try await active.start(request)
            return active
        } catch {
            await active.abortFailedStart()
            throw error
        }
    }

    func cancelPreparation() async {
        guard let prepared else { return }
        self.prepared = nil
        prepared.liveTranscriptionRuntime?.finish()
        for source in prepared.sources {
            await source.stop()
        }
    }

    func scheduleIdleRelease() async {
        services?.scheduleRecordingEnginesRelease()
    }
}

private actor BenchSyntheticStartRecordingSession: StartRecordingSession {
    typealias TranscriberLoader = LiveTranscriptionAttacher.Loader

    private let recordingSession: RecordingSession
    private let sources: [BenchSyntheticAudioCaptureSource]
    private let expectedFrames: Int64
    private let microphone: BenchSyntheticAudioCaptureSource?
    private var initialLiveTranscriptionRuntime: LiveTranscriptionRuntime?
    private let transcriberLoader: TranscriberLoader
    private let telemetry: ResourceWorkloadTelemetry
    private var liveAttacher: LiveTranscriptionAttacher?
    private var stoppedCapture: StopRecordingCapture?

    init(
        outputDirectory: URL,
        sources: [BenchSyntheticAudioCaptureSource],
        expectedFrames: Int64,
        liveTranscriptionRuntime: LiveTranscriptionRuntime?,
        transcriberLoader: @escaping TranscriberLoader,
        telemetry: ResourceWorkloadTelemetry
    ) {
        recordingSession = RecordingSession(outputDirectory: outputDirectory)
        self.sources = sources
        self.expectedFrames = expectedFrames
        microphone = sources.first(where: { $0.channel == .microphone })
        initialLiveTranscriptionRuntime = liveTranscriptionRuntime
        self.transcriberLoader = transcriberLoader
        self.telemetry = telemetry
    }

    func start(_ request: StartRecordingCaptureRequest) async throws {
        let initialRuntime = initialLiveTranscriptionRuntime
        initialLiveTranscriptionRuntime = nil
        let attacher = LiveTranscriptionAttacher(
            channels: sources.map(\.channel),
            hints: TranscriptionHints(
                language: request.languageHint,
                vocabulary: request.vocabulary,
                meetingID: request.meetingID),
            callbacks: request.callbacks,
            initialRuntime: initialRuntime,
            telemetry: telemetry)
        liveAttacher = attacher
        let feeds = attacher.feeds
        let chunk = request.callbacks.chunk
        let level = request.callbacks.level
        do {
            try await recordingSession.start(sources: sources) { audio in
                feeds.yield(audio)
                chunk(audio)
            } onLevel: { sample in
                level(sample)
            } onHealthEvent: { event in
                request.callbacks.health(event)
            }
            await attacher.recordingDidStart(loader: transcriberLoader)
        } catch {
            _ = await finishLiveStreams()
            throw error
        }
    }

    func stop() async -> StopRecordingCapture {
        if let stoppedCapture { return stoppedCapture }
        let summary = await recordingSession.stop()
        let transcriptRequiresRecovery = await finishLiveStreams()
        let capture = if BenchSyntheticCapturePolicy.hasExactFrames(
            summary.framesWritten,
            expectedFrames: expectedFrames
        ) {
            StopRecordingCapture(
                summary,
                transcriptRequiresRecovery: transcriptRequiresRecovery)
        } else {
            StopRecordingCapture(
                publishedFiles: [:],
                transcriptRequiresRecovery: true)
        }
        stoppedCapture = capture
        return capture
    }

    func voiceprint() async -> Voiceprint? { nil }

    func cancelVoiceprintRead() async {}

    nonisolated func setMicrophoneMuted(_ value: Bool) {
        microphone?.setMuted(value)
    }

    func abortFailedStart() async {
        _ = await recordingSession.stop()
        _ = await finishLiveStreams()
    }

    private func finishLiveStreams() async -> Bool {
        guard let liveAttacher else {
            let runtime = initialLiveTranscriptionRuntime
            initialLiveTranscriptionRuntime = nil
            await runtime?.finish()
            return runtime == nil
        }
        self.liveAttacher = nil
        return await liveAttacher.finish()
    }
}

/// Real-time, bounded public signal used only by the exact resource admission
/// above. It exercises the production RecordingSession writers and live model
/// feeds without touching AVAudioEngine, process taps, TCC, or user audio.
final class BenchSyntheticAudioCaptureSource: AudioCaptureSource, @unchecked Sendable {
    let channel: AudioChannel

    private static let mutedSamples = Array(
        repeating: Float.zero,
        count: BenchSyntheticCapturePolicy.chunkFrames)

    private let lock = NSLock()
    private let activeSamples: [Float]
    private let expectedFrames: Int64
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    private var producer: Task<Void, Never>?
    private var muted = false
    private var nextFrame: Int64 = 0

    init?(channel: AudioChannel, expectedFrames: Int64) {
        guard expectedFrames > 0,
              expectedFrames.isMultiple(
                of: Int64(BenchSyntheticCapturePolicy.chunkFrames))
        else { return nil }
        self.channel = channel
        self.expectedFrames = expectedFrames
        let amplitude: Float = channel == .microphone ? 0.03125 : 0.046875
        let phase = channel == .microphone ? 0 : 1
        activeSamples = (0..<BenchSyntheticCapturePolicy.chunkFrames).map { index in
            (index + phase).isMultiple(of: 2) ? amplitude : -amplitude
        }
    }

    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<AudioChunk, Error>
            .makeStream()
        let admitted = lock.withLock { () -> Bool in
            guard self.continuation == nil, producer == nil else { return false }
            self.continuation = continuation
            nextFrame = 0
            producer = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.produce()
            }
            return true
        }
        guard admitted else { throw BenchSyntheticCaptureError.alreadyStarted }
        return stream
    }

    func stop() async {
        let stopped = lock.withLock { () -> Task<Void, Never>? in
            let result = producer
            producer = nil
            return result
        }
        stopped?.cancel()
        await stopped?.value

        // Stop must always drain the same public input. A wall-clock-only
        // producer can be pre-empted just before a tick, leaving a different
        // final Parakeet window in each repeated resource sample. Once the
        // real-time task has stopped, synchronously publish only the bounded
        // missing tail before closing the stream. Product capture never uses
        // this benchmark-only source.
        while let next = lock.withLock({ nextChunk() }) {
            switch next.0.yield(next.1) {
            case .enqueued:
                break
            case .dropped, .terminated:
                break
            @unknown default:
                break
            }
        }
        let continuation = lock.withLock { () -> AsyncThrowingStream<
            AudioChunk, Error
        >.Continuation? in
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.finish()
    }

    func setMuted(_ value: Bool) {
        lock.withLock { muted = value }
    }

    private func produce() async {
        while !Task.isCancelled {
            let next = lock.withLock { nextChunk() }
            guard let next else { return }
            switch next.0.yield(next.1) {
            case .enqueued:
                break
            case .dropped, .terminated:
                return
            @unknown default:
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
    }

    private func nextChunk() -> (
        AsyncThrowingStream<AudioChunk, Error>.Continuation,
        AudioChunk
    )? {
        guard let continuation, nextFrame < expectedFrames else { return nil }
        let timestamp = Double(nextFrame)
            / BenchSyntheticCapturePolicy.sampleRate
        let samples = muted && channel == .microphone
            ? Self.mutedSamples
            : activeSamples
        nextFrame += Int64(samples.count)
        return (continuation, AudioChunk(
            channel: channel,
            samples: samples,
            sampleRate: BenchSyntheticCapturePolicy.sampleRate,
            timestamp: timestamp))
    }
}

enum BenchSyntheticCaptureError: Error, Equatable, LocalizedError {
    case alreadyStarted
    case invalidAdmission
    case syntheticInputRequired

    var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            "the synthetic capture source was already started"
        case .invalidAdmission:
            "synthetic resource capture requires the complete disposable admission"
        case .syntheticInputRequired:
            "resource recording requires the public synthetic capture input"
        }
    }
}
