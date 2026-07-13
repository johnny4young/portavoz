import AudioCaptureKit
import Foundation
import PortavozCore
import SwiftUI
import TranscriptionKit

/// A caption source, erased so the macOS-26-only transcriber type never
/// escapes into code compiled for the app's macOS 14 floor.
private struct CaptionFeed {
    let feed: (AudioChunk) -> Void
    let finish: () -> Void
    let wait: () async -> Void
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

    private var job: Task<Void, Never>?

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
        job = Task { await run() }
    }

    func cancel() {
        job?.cancel()
        job = nil
        if isBusy { phase = .idle }
    }

    private func reset() {
        caption = ""
        level = 0
        secondsLeft = Self.captureSeconds
        capturedSamples = []
    }

    private func run() async {
        do {
            let microphone = MicrophoneSource(voiceProcessing: false)
            let micStream = try await microphone.start()
            defer { Task { await microphone.stop() } }

            let captions = await startCaptionFeed()
            phase = .listening

            let start = Date()
            for try await chunk in micStream {
                if Task.isCancelled { break }
                capturedSamples.append(contentsOf: chunk.samples)
                capturedSampleRate = chunk.sampleRate
                captions?.feed(chunk)
                updateLevel(from: chunk.samples)
                let elapsed = Date().timeIntervalSince(start)
                secondsLeft = max(0, Self.captureSeconds - Int(elapsed))
                if elapsed >= Double(Self.captureSeconds) { break }
            }
            captions?.finish()
            await captions?.wait()

            level = 0
            phase = captions == nil ? .captionsUnavailable : .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Build the on-device caption feed if this OS has `SpeechAnalyzer`; nil
    /// means pre-macOS 26 — the listen still records audio, just without text.
    private func startCaptionFeed() async -> CaptionFeed? {
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
        let consume = Task { @MainActor [weak self] in
            var settled = ""
            do {
                for try await segment in segments {
                    let text = segment.text.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    if segment.isFinal {
                        settled = settled.isEmpty ? text : settled + " " + text
                        self?.applyCaption(settled: settled, volatile: "")
                    } else {
                        self?.applyCaption(settled: settled, volatile: text)
                    }
                }
            } catch {
                // A late failure just freezes the caption where it is; the
                // listen still completes on the audio deadline.
            }
        }
        return CaptionFeed(
            feed: { continuation.yield($0) },
            finish: { continuation.finish() },
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
