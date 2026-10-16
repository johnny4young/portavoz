import Foundation
import os
import PortavozCore

/// Session-owned speech evidence over a copy of the admitted PCM, consumed off
/// the capture callback. It fails open: only a complete, error-free pass that
/// never saw speech reports `.noSpeech`; any doubt is `.undetermined`.
final class DictationSpeechGate: Sendable {
    enum Verdict: Equatable, Sendable {
        case speech
        case noSpeech
        case undetermined
    }

    /// Returns whether a chunk contained speech. Throwing means no evidence.
    typealias Detector = @Sendable (AudioChunk) async throws -> Bool

    /// About 50 s of 4,096-frame chunks at 48 kHz; dropping any audio forfeits the verdict.
    static let capacity = 512
    static let verdictTimeout: Duration = .milliseconds(300)

    private struct Flags {
        var dropped = false
        var heardSpeech = false
    }

    private let continuation: AsyncStream<AudioChunk>.Continuation
    private let flags = OSAllocatedUnfairLock(initialState: Flags())
    private let analysis: Task<Verdict, Never>

    init(load: @escaping @Sendable () async throws -> Detector) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .bufferingNewest(Self.capacity))
        self.continuation = continuation
        let flags = flags
        analysis = Task {
            guard let detect = try? await load() else { return .undetermined }
            do {
                for await chunk in stream {
                    try Task.checkCancellation()
                    // The first speech decides; later audio cannot undo it.
                    if try await detect(chunk) {
                        flags.withLock { $0.heardSpeech = true }
                        return .speech
                    }
                }
            } catch {
                return .undetermined
            }
            if Task.isCancelled { return .undetermined }
            return flags.withLock { $0.dropped } ? .undetermined : .noSpeech
        }
    }

    /// Called from the capture pump; never blocks it.
    func offer(_ chunk: AudioChunk) {
        guard !flags.withLock({ $0.heardSpeech }) else { return }
        if case .dropped = continuation.yield(chunk) {
            flags.withLock { $0.dropped = true }
        }
    }

    func cancel() {
        continuation.finish()
        analysis.cancel()
    }

    /// Ends the audio and returns the verdict, or `.undetermined` when analysis
    /// has not completed within `timeout`.
    func verdict(within timeout: Duration = verdictTimeout) async -> Verdict {
        continuation.finish()
        let analysis = analysis
        return await withCheckedContinuation { continuation in
            let race = DictationSpeechGateRace(continuation)
            Task { race.resolve(await analysis.value) }
            Task {
                try? await Task.sleep(for: timeout)
                if race.resolve(.undetermined) { analysis.cancel() }
            }
        }
    }
}

/// Resumes once with whichever of the analysis and the deadline arrives first.
private final class DictationSpeechGateRace: Sendable {
    private let pending: OSAllocatedUnfairLock<CheckedContinuation<DictationSpeechGate.Verdict, Never>?>

    init(_ continuation: CheckedContinuation<DictationSpeechGate.Verdict, Never>) {
        pending = OSAllocatedUnfairLock(initialState: continuation)
    }

    @discardableResult
    func resolve(_ verdict: DictationSpeechGate.Verdict) -> Bool {
        let continuation = pending.withLock { pending in
            defer { pending = nil }
            return pending
        }
        continuation?.resume(returning: verdict)
        return continuation != nil
    }
}
