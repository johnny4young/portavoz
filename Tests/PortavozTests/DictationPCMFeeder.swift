import Foundation
import PortavozCore

/// Shared public-PCM pacing for model-only and real-controller observations.
enum DictationPCMFeeder {
    static func validate(_ samples: [Float]) throws {
        guard !samples.isEmpty, samples.count <= 1_920_000,
              samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
            throw DictationModelProbe.Failure.invalidInput
        }
    }

    static func feed(
        samples: [Float], started: ContinuousClock.Instant,
        pace: DictationModelProbe.Pace,
        emit: @Sendable (AudioChunk) throws -> Void
    ) async throws {
        for start in stride(from: 0, to: samples.count, by: 1_600) {
            try Task.checkCancellation()
            let limit = min(start + 1_600, samples.count)
            try await pace(started.advanced(by: .seconds(Double(limit) / 16_000)))
            try Task.checkCancellation()
            try emit(AudioChunk(
                channel: .microphone, samples: Array(samples[start..<limit]),
                sampleRate: 16_000, timestamp: Double(start) / 16_000))
        }
    }
}
