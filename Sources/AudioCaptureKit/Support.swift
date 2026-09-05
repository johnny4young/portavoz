import AVFAudio
import Foundation

public enum AudioCaptureError: Error, Sendable {
    case noInputDevice
    case coreAudioError(operation: String, status: Int32)
    case processNotFound(Int32)
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

enum Resample {
    /// Linear-interpolation resampler for mono Float samples. Quality is
    /// plenty for speech and it keeps the capture path dependency-free; it
    /// only runs when a replacement input device (mid-recording headphone
    /// switch) uses a different rate than the one the recording started with.
    static func linear(_ samples: [Float], from source: Double, to target: Double) throws -> [Float] {
        let plan = try CapturePCMGeometry.resampling(inputCount: samples.count, source: source, target: target)
        guard source != target, !samples.isEmpty else { return samples }
        let ratio = plan.ratio
        let count = plan.frameCount
        var out = [Float](repeating: 0, count: count)
        let last = samples.count - 1
        for index in 0..<count {
            let position = Double(index) * ratio
            let base = min(Int(position), last)
            let fraction = Float(position - Double(base))
            let a = samples[base]
            let b = samples[min(base + 1, last)]
            out[index] = a + (b - a) * fraction
        }
        return out
    }
}
