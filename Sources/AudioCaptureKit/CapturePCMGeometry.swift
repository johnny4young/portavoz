import AVFAudio
import Foundation

/// Checked numeric/native-capacity admission, not a physical-memory budget.
/// Keep arithmetic failures outside native format construction and allocation.
enum CapturePCMGeometry {
    struct Resampling: Equatable, Sendable {
        let ratio: Double
        let frameCount: Int
    }

    struct Delivery: Equatable, Sendable {
        let paddingFrameCount: Int
        let paddingTimestamp: TimeInterval
        let deliveredFrameCount: Int
    }

    static func isUsable(sampleRate: Double) -> Bool {
        sampleRate.isFinite && sampleRate > 0
    }

    static func nativeFrameCount(_ count: Int) throws -> AVAudioFrameCount {
        guard let value = AVAudioFrameCount(exactly: count) else {
            throw AudioCaptureError.unsupportedFormat
        }
        return value
    }

    static func resampling(inputCount: Int, source: Double, target: Double) throws -> Resampling {
        guard isUsable(sampleRate: source), isUsable(sampleRate: target) else {
            throw AudioCaptureError.unsupportedFormat
        }
        _ = try nativeFrameCount(inputCount)
        let ratio = source / target
        guard ratio.isFinite, ratio > 0 else { throw AudioCaptureError.unsupportedFormat }
        guard inputCount > 0 else { return Resampling(ratio: ratio, frameCount: 0) }
        guard let rounded = Int(exactly: (Double(inputCount) / ratio).rounded(.down)) else {
            throw AudioCaptureError.unsupportedFormat
        }
        let count = max(1, rounded)
        _ = try nativeFrameCount(count)
        return Resampling(ratio: ratio, frameCount: count)
    }

    static func delivery(
        elapsed: TimeInterval, sampleRate: Double, delivered: Int, incoming: Int
    ) throws -> Delivery {
        guard elapsed.isFinite, isUsable(sampleRate: sampleRate), delivered >= 0,
              let expected = Int(exactly: (elapsed * sampleRate).rounded(.towardZero))
        else { throw AudioCaptureError.unsupportedFormat }
        _ = try nativeFrameCount(incoming)
        let (gap, gapOverflow) = expected.subtractingReportingOverflow(delivered)
        guard !gapOverflow else { throw AudioCaptureError.unsupportedFormat }
        // For integer gaps this preserves the original > floor(rate / 2)
        // threshold without first converting an unchecked rate to Int.
        let padding = gap > 0 && Double(gap) > sampleRate / 2 ? gap : 0
        _ = try nativeFrameCount(padding)
        let (afterPadding, paddingOverflow) = delivered.addingReportingOverflow(padding)
        let (total, incomingOverflow) = afterPadding.addingReportingOverflow(incoming)
        let timestamp = padding > 0 ? Double(delivered) / sampleRate : 0
        guard !paddingOverflow, !incomingOverflow, timestamp.isFinite else {
            throw AudioCaptureError.unsupportedFormat
        }
        return Delivery(paddingFrameCount: padding, paddingTimestamp: timestamp, deliveredFrameCount: total)
    }
}
