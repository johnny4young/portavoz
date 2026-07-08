import AVFoundation
import Foundation

/// Downsamples a meeting's audio into a fixed number of amplitude columns
/// for the scrubber waveform (M11/D27). Each column also records whether
/// the microphone (you) or the system channel (them) was louder there, so
/// the render can tint "who was talking" without full diarization.
public enum Waveform {
    public struct Bucket: Sendable, Equatable {
        /// Peak amplitude in this slice, normalized to 0…1 across the meeting.
        public let amplitude: Float
        /// True when your mic was louder than the system channel here.
        public let micDominant: Bool

        public init(amplitude: Float, micDominant: Bool) {
            self.amplitude = amplitude
            self.micDominant = micDominant
        }
    }

    /// Pure and synchronous — a long meeting reads a lot of frames, so call
    /// it from a background task. Returns `[]` when nothing is readable.
    public static func generate(micFile: URL?, systemFile: URL?, buckets: Int) -> [Bucket] {
        guard buckets > 0 else { return [] }
        let mic = envelope(of: micFile, buckets: buckets)
        let system = envelope(of: systemFile, buckets: buckets)
        guard !mic.isEmpty || !system.isEmpty else { return [] }

        var raw = [(amplitude: Float, micDominant: Bool)](
            repeating: (0, false), count: buckets)
        var peak: Float = 0
        for index in 0..<buckets {
            let m = index < mic.count ? mic[index] : 0
            let s = index < system.count ? system[index] : 0
            let amp = max(m, s)
            raw[index] = (amp, m >= s)
            peak = max(peak, amp)
        }
        let scale = peak > 0 ? 1 / peak : 1
        return raw.map { Bucket(amplitude: min(1, $0.amplitude * scale), micDominant: $0.micDominant) }
    }

    /// Per-bucket peak amplitude of one file (empty when unreadable).
    private static func envelope(of url: URL?, buckets: Int) -> [Float] {
        guard let url, let file = try? AVAudioFile(forReading: url) else { return [] }
        let total = file.length
        guard total > 0 else { return [] }

        let framesPerBucket = max(1, Int(total) / buckets)
        var result = [Float](repeating: 0, count: buckets)
        let chunkCapacity = AVAudioFrameCount(min(Int(total), 1 << 16))
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: chunkCapacity)
        else { return result }

        var frameIndex = 0
        while file.framePosition < total {
            do { try file.read(into: buffer) } catch { break }
            let count = Int(buffer.frameLength)
            guard count > 0, let channelData = buffer.floatChannelData else { break }
            let channels = Int(buffer.format.channelCount)
            for i in 0..<count {
                var sample: Float = 0
                for c in 0..<channels { sample = max(sample, abs(channelData[c][i])) }
                let bucket = min(buckets - 1, (frameIndex + i) / framesPerBucket)
                result[bucket] = max(result[bucket], sample)
            }
            frameIndex += count
        }
        return result
    }
}
