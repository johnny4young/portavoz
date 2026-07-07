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
    public struct Result: Sendable {
        public var finals = 0
        public var volatiles = 0
        public var characters = 0
        public var firstResultAt: Double?
        public var lags: [Double] = []

        public func percentile(_ p: Double) -> Double {
            guard !lags.isEmpty else { return 0 }
            return lags[min(lags.count - 1, Int(Double(lags.count) * p))]
        }

        public var report: String {
            var lines = ["finales: \(finals) · volátiles: \(volatiles) · chars: \(characters)"]
            if let firstResultAt {
                lines.append(String(format: "primer resultado: %.2fs", firstResultAt))
            }
            lines.append(String(
                format: "lag de finalización — p50 %.2fs · p95 %.2fs · max %.2fs",
                percentile(0.5), percentile(0.95), lags.last ?? 0))
            return lines.joined(separator: "\n")
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
        let audioFile = try AVAudioFile(forReading: file)
        let rate = audioFile.processingFormat.sampleRate
        let totalSeconds = min(Double(seconds), Double(audioFile.length) / rate)

        let (stream, feed) = AsyncStream.makeStream(of: AudioChunk.self)
        let segments = transcribe(stream)

        // Feeder: 1 s chunks at real-time pace — never faster than the clock.
        let feedStart = Date()
        let feeder = Task {
            let chunkFrames = AVAudioFrameCount(rate)
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: audioFile.processingFormat, frameCapacity: chunkFrames)
            else { return }
            var fedSeconds = 0.0
            while fedSeconds < totalSeconds {
                do {
                    try audioFile.read(into: buffer, frameCount: chunkFrames)
                } catch { break }
                guard buffer.frameLength > 0 else { break }
                let samples = monoSamples(from: buffer)
                feed.yield(
                    AudioChunk(
                        channel: .microphone, samples: samples,
                        sampleRate: rate, timestamp: fedSeconds))
                fedSeconds += Double(buffer.frameLength) / rate
                let target = feedStart.addingTimeInterval(fedSeconds)
                let wait = target.timeIntervalSinceNow
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                }
            }
            feed.finish()
        }

        var result = Result()
        do {
            for try await segment in segments {
                let elapsed = Date().timeIntervalSince(feedStart)
                if result.firstResultAt == nil { result.firstResultAt = elapsed }
                if segment.isFinal {
                    result.finals += 1
                    result.characters += segment.text.count
                    result.lags.append(elapsed - segment.endTime)
                    log(String(
                        format: "[%6.2fs] final lag %+5.2fs  %@",
                        elapsed, elapsed - segment.endTime,
                        String(segment.text.prefix(70))))
                } else {
                    result.volatiles += 1
                }
            }
        } catch {
            log("stream error: \(error.localizedDescription)")
        }
        feeder.cancel()
        result.lags.sort()
        return result
    }
}
