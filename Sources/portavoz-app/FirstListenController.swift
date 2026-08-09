import AudioCaptureKit
import Foundation
import PortavozCore
import SwiftUI
import TranscriptionKit

/// A caption source, erased so the macOS-26-only transcriber type never
/// escapes into code compiled for the app's macOS 14 floor.
struct FirstListenCaptionFeed: Sendable {
    let feed: @Sendable (AudioChunk) -> Void
    let finish: @Sendable () -> Void
    let cancel: @Sendable () -> Void
    let wait: @Sendable () async -> Void
}

/// One started microphone stream plus the asynchronous teardown that owns its
/// tap and engine. Tests inject this boundary without touching a real device.
struct FirstListenAudioCapture: Sendable {
    let chunks: AsyncThrowingStream<AudioChunk, Error>
    let stop: @Sendable () async -> Void
}

/// The onboarding "first listen" (design system 6a-4): before any 1 GB model
/// download, let the user say one sentence and watch Portavoz transcribe it
/// live, 100% on-device, using Apple's `SpeechAnalyzer` (macOS 26, no app
/// model needed). The 10 s of audio doubles as the voice-enrollment sample so
/// the user never has to speak twice. Everything is local; nothing is stored
/// unless the user chooses to enroll.
@MainActor
@Observable
final class FirstListenController {
    typealias CaptureFactory = @MainActor @Sendable () async throws -> FirstListenAudioCapture
    typealias CaptionFactory = @MainActor @Sendable (
        _ apply: @escaping @MainActor @Sendable (String, String) -> Void
    ) async -> FirstListenCaptionFeed?

    enum Phase: Equatable {
        case idle
        case preparing
        case listening
        case done
        /// Live captions need macOS 26; older systems still hear the audio.
        case captionsUnavailable
        case failed(String)
    }

    /// How long the demo listens — short enough to keep onboarding < 60 s.
    static let captureSeconds = 10

    private(set) var phase: Phase = .idle
    /// The live caption: settled text plus the still-changing tail.
    private(set) var caption = ""
    /// Smoothed 0…1 microphone level, for the breathing waveform.
    private(set) var level: Double = 0
    private(set) var secondsLeft = FirstListenController.captureSeconds

    /// The captured mono audio, reused for voice enrollment so the user
    /// doesn't record a second time.
    private(set) var capturedSamples: [Float] = []
    private(set) var capturedSampleRate: Double = 16_000

    private let captureFactory: CaptureFactory
    private let captionFactory: CaptionFactory
    private var job: Task<Void, Never>?
    private var activeSessionID: UUID?

    init(
        captureFactory: CaptureFactory? = nil,
        captionFactory: CaptionFactory? = nil
    ) {
        self.captureFactory = captureFactory ?? Self.startLiveCapture
        self.captionFactory = captionFactory ?? Self.startLiveCaptionFeed
    }

    var hasCaption: Bool { !caption.trimmingCharacters(in: .whitespaces).isEmpty }

    var wordCount: Int {
        caption.split { $0 == " " || $0 == "\n" }.count
    }

    var isBusy: Bool { phase == .preparing || phase == .listening }

    /// Begin the 10 s listen: capture the mic, fan each chunk out to both the
    /// live transcriber and the sample buffer (for optional enrollment).
    func start() {
        guard !isBusy else { return }
        reset()
        phase = .preparing
        let sessionID = UUID()
        activeSessionID = sessionID
        job = Task { [weak self] in
            await self?.run(sessionID: sessionID)
        }
    }

    func cancel() {
        let discardedPartialCapture = isBusy
        activeSessionID = nil
        job?.cancel()
        job = nil
        if discardedPartialCapture {
            phase = .idle
            capturedSamples = []
            secondsLeft = Self.captureSeconds
        }
        level = 0
    }

    private func reset() {
        caption = ""
        level = 0
        secondsLeft = Self.captureSeconds
        capturedSamples = []
    }

    private func run(sessionID: UUID) async {
        var capture: FirstListenAudioCapture?
        var captions: FirstListenCaptionFeed?
        do {
            captions = await captionFactory { [weak self] settled, volatile in
                guard let self, self.activeSessionID == sessionID else { return }
                self.applyCaption(settled: settled, volatile: volatile)
            }
            try requireActive(sessionID)
            let captionsAvailable = captions != nil
            // Resolve Apple's optional caption asset before opening the mic.
            // Otherwise its live stream buffers while the asset awaits and a
            // cold first listen can retain an unbounded audio backlog.
            let startedCapture = try await captureFactory()
            capture = startedCapture
            try requireActive(sessionID)
            phase = .listening

            let start = Date()
            for try await chunk in startedCapture.chunks {
                try requireActive(sessionID)
                capturedSamples.append(contentsOf: chunk.samples)
                capturedSampleRate = chunk.sampleRate
                captions?.feed(chunk)
                updateLevel(from: chunk.samples)
                let elapsed = Date().timeIntervalSince(start)
                secondsLeft = max(0, Self.captureSeconds - Int(elapsed))
                if elapsed >= Double(Self.captureSeconds) { break }
            }
            try requireActive(sessionID)
            captions?.finish()
            await startedCapture.stop()
            capture = nil
            await Self.waitForCompletion(of: captions)
            captions = nil
            try requireActive(sessionID)

            level = 0
            phase = captionsAvailable ? .done : .captionsUnavailable
            activeSessionID = nil
            job = nil
        } catch is CancellationError {
            captions?.cancel()
            await capture?.stop()
            await captions?.wait()
            guard activeSessionID == sessionID else { return }
            activeSessionID = nil
            job = nil
            level = 0
            capturedSamples = []
            secondsLeft = Self.captureSeconds
            phase = .idle
        } catch {
            captions?.cancel()
            await capture?.stop()
            await captions?.wait()
            guard activeSessionID == sessionID, !Task.isCancelled else { return }
            activeSessionID = nil
            job = nil
            level = 0
            phase = .failed(error.localizedDescription)
        }
    }

    private func requireActive(_ sessionID: UUID) throws {
        try Task.checkCancellation()
        guard activeSessionID == sessionID else { throw CancellationError() }
    }

    private static func waitForCompletion(of captions: FirstListenCaptionFeed?) async {
        guard let captions else { return }
        await withTaskCancellationHandler {
            await captions.wait()
        } onCancel: {
            captions.cancel()
        }
    }

    private static func startLiveCapture() async throws -> FirstListenAudioCapture {
        let microphone = MicrophoneSource(voiceProcessing: false)
        let chunks = try await microphone.start()
        return FirstListenAudioCapture(
            chunks: chunks,
            stop: { await microphone.stop() })
    }

    /// Build the on-device caption feed if this OS has `SpeechAnalyzer`; nil
    /// means pre-macOS 26 — the listen still records audio, just without text.
    private static func startLiveCaptionFeed(
        apply: @escaping @MainActor @Sendable (String, String) -> Void
    ) async -> FirstListenCaptionFeed? {
        guard #available(macOS 26.0, *), SpeechAnalyzerEngine.isAvailable else { return nil }
        let locale: Locale
        do {
            locale = try await SpeechAnalyzerEngine.ensureAssets(language: nil)
        } catch {
            return nil
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let segments = SpeechAnalyzerEngine()
            .transcribe(stream, hints: TranscriptionHints(), locale: locale)
        let consume = Task { @MainActor in
            var settled = ""
            do {
                for try await segment in segments {
                    let text = segment.text.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    if segment.isFinal {
                        settled = settled.isEmpty ? text : settled + " " + text
                        apply(settled, "")
                    } else {
                        apply(settled, text)
                    }
                }
            } catch {
                // A late failure just freezes the caption where it is; the
                // listen still completes on the audio deadline.
            }
        }
        return FirstListenCaptionFeed(
            feed: { continuation.yield($0) },
            finish: { continuation.finish() },
            cancel: {
                consume.cancel()
                continuation.finish()
            },
            wait: { await consume.value })
    }

    private func applyCaption(settled: String, volatile: String) {
        caption = [settled, volatile]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Simple RMS → 0…1, smoothed so the waveform breathes rather than jitters.
    private func updateLevel(from samples: [Float]) {
        guard !samples.isEmpty else { return }
        let meanSquare = samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count)
        let rms = meanSquare.squareRoot()
        let target = min(1, rms * 6)  // demo mics run quiet; lift for visibility
        level += (target - level) * 0.35
    }
}
