import AVFoundation
import Foundation
import PortavozCore

/// The M12 decision harness: paces a recording through an engine in REAL
/// TIME (1 s chunks, wall-clock aligned) and measures finalization lag per
/// segment: wallclock_when_emitted − feed_start − segment.endTime.
/// Engine-agnostic and host-agnostic on purpose — the CLI drives Parakeet
/// with it, and the APP drives SpeechAnalyzer, which refuses to answer
/// outside a real bundle (the spike's gotcha: unbundled CLI = parked
/// forever on the first await).
public enum LiveTranscriptionBench {
    public enum BenchError: Error, Equatable, LocalizedError, Sendable {
        case invalidDuration(Int)
        case invalidAudioFormat
        case engineEndedBeforeInput
        case inputEndedBeforeTarget

        public var errorDescription: String? {
            switch self {
            case .invalidDuration(let seconds):
                return "benchmark duration must be positive, got \(seconds)"
            case .invalidAudioFormat:
                return "benchmark audio must have a finite positive sample rate and channels"
            case .engineEndedBeforeInput:
                return "transcription engine ended before the benchmark input finished"
            case .inputEndedBeforeTarget:
                return "benchmark audio ended before its requested frame count"
            }
        }
    }

    public struct Result: Sendable {
        public var finals = 0
        public var volatiles = 0
        public var characters = 0
        public var firstResultAt: Double?
        public var lags: [Double] = []
        /// Every final row in emission order. This is useful for measuring
        /// confirmation, but is not necessarily what Dictation would insert.
        public var finalTexts: [String] = []
        /// The successful stream's recognized Dictation text before user text
        /// rules, composed through the same caption admission path as the
        /// controller. Short speech can have no final row at all.
        public internal(set) var dictationRecognizedText = ""

        public var hypothesis: String {
            finalTexts.joined(separator: " ")
        }

        public func percentile(_ p: Double) -> Double {
            guard !lags.isEmpty else { return 0 }
            return lags[min(lags.count - 1, Int(Double(lags.count) * p))]
        }

        public var report: String {
            var lines = ["final: \(finals) · volatile: \(volatiles) · chars: \(characters)"]
            if let firstResultAt {
                lines.append(String(format: "primer resultado: %.2fs", firstResultAt))
            }
            lines.append(String(
                format: "finalization lag — p50 %.2fs · p95 %.2fs · max %.2fs",
                percentile(0.5), percentile(0.95), lags.last ?? 0))
            return lines.joined(separator: "\n")
        }

        mutating func observe(
            _ segment: TranscriptSegment,
            elapsed: TimeInterval,
            log: @Sendable (String) -> Void
        ) {
            if firstResultAt == nil { firstResultAt = elapsed }
            if segment.isFinal {
                finals += 1
                characters += segment.text.count
                finalTexts.append(segment.text)
                lags.append(elapsed - segment.endTime)
                log(String(
                    format: "[%6.2fs] final lag %+5.2fs  %@",
                    elapsed, elapsed - segment.endTime,
                    String(segment.text.prefix(70))))
            } else {
                volatiles += 1
            }
        }
    }

    /// Averages all channels into mono.
    private static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return [] }
        let channels = Int(buffer.format.channelCount)
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: data[0], count: frames))
        }
        var out = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            let pointer = data[channel]
            for frame in 0..<frames { out[frame] += pointer[frame] }
        }
        let scale = 1 / Float(channels)
        for frame in 0..<frames { out[frame] *= scale }
        return out
    }

    private static func feedAudio(
        _ audioFile: AVAudioFile,
        rate: Double,
        targetFrames: AVAudioFramePosition,
        into feed: AsyncStream<AudioChunk>.Continuation,
        startedAt feedStart: Date
    ) async throws {
        defer { feed.finish() }
        let chunkFrames = AVAudioFrameCount(rate)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: chunkFrames)
        else { throw BenchError.invalidAudioFormat }

        var fedFrames: AVAudioFramePosition = 0
        while fedFrames < targetFrames {
            try Task.checkCancellation()
            let remaining = targetFrames - fedFrames
            try audioFile.read(
                into: buffer,
                frameCount: AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining)))
            guard buffer.frameLength > 0 else { throw BenchError.inputEndedBeforeTarget }
            let samples = monoSamples(from: buffer)
            feed.yield(AudioChunk(
                channel: .microphone,
                samples: samples,
                sampleRate: rate,
                timestamp: Double(fedFrames) / rate))
            fedFrames += AVAudioFramePosition(buffer.frameLength)
            let fedSeconds = Double(fedFrames) / rate
            let wait = feedStart.addingTimeInterval(fedSeconds).timeIntervalSinceNow
            if wait > 0 {
                try await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// Feeds `file` in real time into `transcribe` and measures per-final
    /// lag. `log` receives one line per final segment as it lands.
    public static func run(
        file: URL,
        seconds: Int,
        transcribe: @Sendable (AsyncStream<AudioChunk>) -> AsyncThrowingStream<
            TranscriptSegment, Error
        >,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> Result {
        guard seconds > 0 else { throw BenchError.invalidDuration(seconds) }
        let audioFile = try AVAudioFile(forReading: file)
        let rate = audioFile.processingFormat.sampleRate
        guard
            rate.isFinite,
            rate >= 1,
            rate <= Double(AVAudioFrameCount.max),
            audioFile.processingFormat.channelCount > 0,
            audioFile.length > 0
        else {
            throw BenchError.invalidAudioFormat
        }
        let requestedFrames = Double(seconds) * rate
        let targetFrames = requestedFrames >= Double(audioFile.length)
            ? audioFile.length
            : AVAudioFramePosition(requestedFrames.rounded(.down))
        guard targetFrames > 0 else { throw BenchError.invalidAudioFormat }

        let (stream, feed) = AsyncStream.makeStream(of: AudioChunk.self)
        let segments = transcribe(stream)

        // Feeder: 1 s chunks at real-time pace — never faster than the clock.
        let feedStart = Date()
        let feeder = Task {
            try await feedAudio(
                audioFile,
                rate: rate,
                targetFrames: targetFrames,
                into: feed,
                startedAt: feedStart)
        }

        var result = Result()
        var captions: [TranscriptSegment] = []
        let coalescer = CaptionCoalescer()
        do {
            for try await segment in segments {
                coalescer.apply(segment, to: &captions)
                let elapsed = Date().timeIntervalSince(feedStart)
                result.observe(segment, elapsed: elapsed, log: log)
            }
        } catch {
            log("stream error: \(error.localizedDescription)")
            feeder.cancel()
            _ = try? await feeder.value
            throw error
        }
        feeder.cancel()
        do {
            try await feeder.value
        } catch is CancellationError {
            throw BenchError.engineEndedBeforeInput
        }
        result.dictationRecognizedText = DictationAssembler.text(
            confirmed: captions.map(\.text).joined(separator: " "), partial: "")
        result.lags.sort()
        return result
    }
}
