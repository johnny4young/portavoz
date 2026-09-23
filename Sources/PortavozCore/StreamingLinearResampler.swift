import Foundation

public enum PCMResamplingError: Error, Sendable {
    case unsupportedGeometry
}

/// Carries interpolation phase between PCM buffers without owning a capture
/// device. Callers provide their own bounded output admission before invoking
/// this off-callback or inside a capture source's existing serialized path.
public struct StreamingLinearResampler: Sendable {
    private var nextPosition = 0.0
    private var carried: Float?
    private var sourceRate: Double?
    private var targetRate: Double?

    public init() {}

    public mutating func reset() {
        nextPosition = 0
        carried = nil
        sourceRate = nil
        targetRate = nil
    }

    /// Mute must discard prior voice without changing the timeline's phase.
    public mutating func discardCarriedSample() {
        carried = nil
    }

    public mutating func resample(
        _ samples: [Float],
        from source: Double,
        to target: Double,
        maximumOutputSamples: Int
    ) throws -> [Float] {
        guard source.isFinite, source > 0, target.isFinite, target > 0,
              maximumOutputSamples >= 0
        else { throw PCMResamplingError.unsupportedGeometry }
        let ratio = source / target
        guard ratio.isFinite, ratio > 0 else {
            throw PCMResamplingError.unsupportedGeometry
        }
        guard !samples.isEmpty else { return [] }

        let changedRates = sourceRate != source || targetRate != target
        let position = changedRates ? 0 : nextPosition
        let previous = changedRates ? nil : carried
        if source == target {
            guard samples.count <= maximumOutputSamples else {
                throw PCMResamplingError.unsupportedGeometry
            }
            nextPosition = 0
            carried = samples.last
            sourceRate = source
            targetRate = target
            return samples
        }

        let last = Double(samples.count - 1)
        let projected = max(0, ((last - position) / ratio).rounded(.up) + 1)
        // The reservation is an upper estimate; the final interpolation step
        // can land past `last`. Admit that one-frame rounding margin and check
        // the actual output count inside the loop.
        guard projected.isFinite,
              projected <= Double(maximumOutputSamples) + 2,
              let reservation = Int(exactly: min(projected, Double(maximumOutputSamples)))
        else {
            throw PCMResamplingError.unsupportedGeometry
        }

        func sample(at index: Int) -> Float {
            if index < 0 { return previous ?? samples[0] }
            return samples[min(index, samples.count - 1)]
        }

        var output: [Float] = []
        output.reserveCapacity(reservation)
        var cursor = position
        while cursor <= last {
            guard output.count < maximumOutputSamples else {
                throw PCMResamplingError.unsupportedGeometry
            }
            let base = Int(cursor.rounded(.down))
            let fraction = Float(cursor - Double(base))
            let start = sample(at: base)
            let end = sample(at: base + 1)
            output.append(start + (end - start) * fraction)
            cursor += ratio
        }
        nextPosition = cursor - Double(samples.count)
        carried = samples.last
        sourceRate = source
        targetRate = target
        return output
    }
}
