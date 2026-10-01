import AVFAudio
import Foundation
import PortavozCore

public enum AudioCaptureError: Error, Sendable {
    case noInputDevice
    case coreAudioError(operation: String, status: Int32)
    case unsupportedFormat
    case invalidCaptureFile(String)
    case captureDestinationExists(String)
    case nonAtomicCapturePublication(String)
    case captureWriterClosed
}

enum AudioRouteTransitionTiming {
    /// Leaves AVFAudio/Core Audio's internal route callback and lets the new
    /// hardware route settle before constructing its replacement graph.
    static let settleDelay: TimeInterval = 0.15

    /// Keeps the capture stream alive while a transient route has no usable
    /// input/output yet, without spinning on the graph queue.
    static let retryDelay: TimeInterval = 0.5
}

/// Invalidates stale audio-graph work when route notifications arrive in
/// bursts or after capture has stopped.
///
/// The owner serializes mutations on its graph queue. Every new request gets a
/// later ticket; delayed work may proceed only while its ticket is still the
/// newest request in the active capture generation.
struct AudioRouteTransitionGate: Sendable {
    struct Ticket: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0
    private(set) var isActive = false

    mutating func activate() {
        generation &+= 1
        isActive = true
    }

    mutating func request() -> Ticket? {
        guard isActive else { return nil }
        generation &+= 1
        return Ticket(generation: generation)
    }

    func admits(_ ticket: Ticket) -> Bool {
        isActive && ticket.generation == generation
    }

    mutating func deactivate() {
        generation &+= 1
        isActive = false
    }
}

/// Converts Core Audio host times into seconds elapsed since the first
/// callback of a session.
///
/// `@unchecked Sendable`: `start` is written exactly once, from the
/// serialized audio callback path that owns this clock.
final class HostClock: @unchecked Sendable {
    private var start: UInt64 = 0

    func elapsed(hostTime: UInt64) -> TimeInterval {
        if start == 0 { start = hostTime }
        return AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: start)
    }
}

/// Linear resampling that keeps its fractional position across buffers.
///
/// Flooring each callback's output count independently drops the remainder
/// every time: 4096 frames at 44.1 kHz into 48 kHz should yield about 4458.23 and
/// yields 4458, accumulating drift. Delivery accounting eventually injects
/// a half-second silence pad to catch up. This
/// carries the phase — and the previous buffer's last sample, so interpolation
/// spans the boundary — which keeps the output aligned with the host clock.
///
/// Not thread-safe: each capture source owns one behind its own lock.
struct LinearResampler {
    private var converter = StreamingLinearResampler()

    mutating func reset() {
        converter.reset()
    }

    /// Mute must discard prior voice without changing the timeline's phase.
    mutating func discardCarriedSample() {
        converter.discardCarriedSample()
    }

    mutating func resample(
        _ samples: [Float],
        from source: Double,
        to target: Double
    ) throws -> [Float] {
        let geometry = try CapturePCMGeometry.resampling(
            inputCount: samples.count, source: source, target: target)
        guard !samples.isEmpty else { return [] }
        let output: [Float]
        do {
            output = try converter.resample(
                samples, from: source, to: target,
                maximumOutputSamples: geometry.frameCount
                    + CaptureDeliveryBuffer.streamingCarryFrames)
        } catch {
            throw AudioCaptureError.unsupportedFormat
        }
        _ = try CapturePCMGeometry.nativeFrameCount(output.count)
        return output
    }
}
