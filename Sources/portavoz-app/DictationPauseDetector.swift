import Foundation
import os
import PortavozCore

/// Watches a copy of the admitted PCM for a pause after speech, off the
/// capture callback. It reports at most once and never early: a dropped chunk
/// or a detector failure turns it off for the session, and silence counts only
/// from `arm()`, once the speech model is ready.
final class DictationPauseDetector: Sendable {
    /// Nil when the chunk completed no detector frame, so it is not evidence of silence.
    typealias Detector = @Sendable (AudioChunk) async throws -> Bool?

    static let capacity = DictationSpeechGate.capacity

    private let continuation: AsyncStream<AudioChunk>.Continuation
    private let dropped = OSAllocatedUnfairLock(initialState: false)
    /// Audio time offered so far, and where the pause clock may start.
    private let clock = OSAllocatedUnfairLock<(offered: TimeInterval, armedAt: TimeInterval?)>(
        initialState: (0, nil))
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
        let clock = clock
        analysis = Task {
            guard let detect = try? await load() else { return }
            var lastSpeechEnd: TimeInterval?
            do {
                for await chunk in stream {
                    try Task.checkCancellation()
                    guard !dropped.withLock({ $0 }), chunk.sampleRate > 0 else { return }
                    let end = chunk.timestamp + Double(chunk.samples.count) / chunk.sampleRate
                    guard let heard = try await detect(chunk) else { continue }
                    if heard {
                        lastSpeechEnd = end
                    } else if let lastSpeechEnd, let armedAt = clock.withLock({ $0.armedAt }),
                              end - max(lastSpeechEnd, armedAt) >= pause {
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
        if chunk.sampleRate > 0 {
            let end = chunk.timestamp + Double(chunk.samples.count) / chunk.sampleRate
            clock.withLock { $0.offered = max($0.offered, end) }
        }
        if case .dropped = continuation.yield(chunk) {
            dropped.withLock { $0 = true }
        }
    }

    var isArmed: Bool { clock.withLock { $0.armedAt != nil } }

    /// Starts the pause clock at the audio offered so far; earlier silence never counts.
    func arm() {
        clock.withLock { if $0.armedAt == nil { $0.armedAt = $0.offered } }
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
