import Foundation
import os
import PortavozCore

/// Watches a copy of the admitted PCM for a pause after speech, off the
/// capture callback. It reports at most once and never early: a dropped chunk
/// or a detector failure turns it off for the session.
final class DictationPauseDetector: Sendable {
    typealias Detector = DictationSpeechGate.Detector

    static let capacity = DictationSpeechGate.capacity

    private let continuation: AsyncStream<AudioChunk>.Continuation
    private let dropped = OSAllocatedUnfairLock(initialState: false)
    private let analysis: Task<Void, Never>

    init(
        pause: TimeInterval,
        load: @escaping @Sendable () async throws -> Detector,
        onPause: @escaping @Sendable () -> Void
    ) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .bufferingNewest(Self.capacity))
        self.continuation = continuation
        let dropped = dropped
        analysis = Task {
            guard let detect = try? await load() else { return }
            var lastSpeechEnd: TimeInterval?
            do {
                for await chunk in stream {
                    try Task.checkCancellation()
                    guard !dropped.withLock({ $0 }), chunk.sampleRate > 0 else { return }
                    let end = chunk.timestamp + Double(chunk.samples.count) / chunk.sampleRate
                    if try await detect(chunk) {
                        lastSpeechEnd = end
                    } else if let lastSpeechEnd, end - lastSpeechEnd >= pause {
                        onPause()
                        return
                    }
                }
            } catch {
                return
            }
        }
    }

    /// Called from the capture pump; never blocks it.
    func offer(_ chunk: AudioChunk) {
        if case .dropped = continuation.yield(chunk) {
            dropped.withLock { $0 = true }
        }
    }

    func cancel() {
        continuation.finish()
        analysis.cancel()
    }
}

/// The session's analyses over the same copy of admitted PCM.
struct DictationSessionAnalysis: Sendable {
    var gate: DictationSpeechGate?
    var pause: DictationPauseDetector?

    func offer(_ chunk: AudioChunk) {
        gate?.offer(chunk)
        pause?.offer(chunk)
    }

    func cancel() {
        gate?.cancel()
        pause?.cancel()
    }
}
