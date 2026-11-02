import Accelerate
import Foundation
import PortavozCore

/// Whisper fills near-silent windows with a word or two stretched over
/// seconds ("Thank you.", "so"). A row is dropped only when it is both close
/// to its channel's noise floor and far slower than anyone speaks, so quiet
/// but real phrases survive.
public enum FaintSpeechFilter {
    static let frameLength: TimeInterval = 0.1
    static let floorPercentile = 0.1
    static let minimumLevelAboveFloor: Float = 10
    static let minimumStretch: TimeInterval = 3
    static let maximumWordsPerSecond = 0.5

    /// Rows worth keeping, and the seconds the dropped rows covered.
    public static func filter(
        _ segments: [TranscriptSegment],
        samples: [Float],
        sampleRate: Double
    ) -> (kept: [TranscriptSegment], droppedSeconds: TimeInterval) {
        let frames = frameLevels(samples, sampleRate: sampleRate)
        guard !frames.isEmpty else { return (segments, 0) }
        let sorted = frames.sorted()
        let floor = max(sorted[Int(Double(sorted.count - 1) * floorPercentile)], 1e-5)
        var kept: [TranscriptSegment] = []
        var dropped: TimeInterval = 0
        for segment in segments {
            if isFaint(segment, frames: frames, floor: floor) {
                dropped += segment.endTime - segment.startTime
            } else {
                kept.append(segment)
            }
        }
        return (kept, dropped)
    }

    static func isFaint(_ segment: TranscriptSegment, frames: [Float], floor: Float) -> Bool {
        let length = segment.endTime - segment.startTime
        guard length >= minimumStretch else { return false }
        let words = segment.text.split(whereSeparator: \.isWhitespace).count
        guard Double(words) / length < maximumWordsPerSecond else { return false }
        let lower = min(frames.count - 1, max(0, Int(segment.startTime / frameLength)))
        let upper = min(frames.count, max(lower + 1, Int(segment.endTime / frameLength)))
        let levels = frames[lower..<upper].sorted()
        let loud = levels[Int(Double(levels.count - 1) * 0.9)]
        return 20 * log10(max(loud, 1e-9) / floor) < minimumLevelAboveFloor
    }

    static func frameLevels(_ samples: [Float], sampleRate: Double) -> [Float] {
        let hop = max(1, Int(sampleRate * frameLength))
        guard samples.count >= hop else { return [] }
        return samples.withUnsafeBufferPointer { buffer in
            stride(from: 0, through: samples.count - hop, by: hop).map { start in
                var level: Float = 0
                vDSP_rmsqv(buffer.baseAddress! + start, 1, &level, vDSP_Length(hop))
                return level
            }
        }
    }
}
