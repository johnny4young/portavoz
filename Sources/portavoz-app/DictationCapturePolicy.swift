import Foundation
import PortavozCore

/// Pure capture-edge policy. The minimum is measured from the moment the
/// first nonempty microphone buffer arrives, never from model preparation or panel
/// presentation, so a slow cold start cannot turn a tap into a valid capture.
struct DictationCapturePolicy {
    static let minimumCapture: TimeInterval = 0.75

    enum FinishDecision: Equatable {
        case cancel
        case stopAfterTail
    }

    static func finishDecision(
        captureStartedAt: Date?, now: Date
    ) -> FinishDecision {
        guard let captureStartedAt,
            now.timeIntervalSince(captureStartedAt) >= minimumCapture
        else { return .cancel }
        return .stopAfterTail
    }
}

/// The relay also holds speech captured while the model loads. Its bound is
/// queued audio time; the chunk count is only a backstop.
enum DictationRelayPolicy {
    // Room for 30 s of 128-frame buffers at 48 kHz, so the time bound decides first.
    static let capacity = 16_384
    static let backlogLimit: TimeInterval = 30

    static func admits(
        _ result: AsyncStream<AudioChunk>.Continuation.YieldResult, chunk: AudioChunk
    ) -> Bool {
        guard case .enqueued(let remaining) = result else { return false }
        let queued = Double(capacity - remaining) * Double(chunk.samples.count) / chunk.sampleRate
        return queued <= backlogLimit
    }
}

enum DictationSessionError: LocalizedError {
    case unexpectedCompletion

    var errorDescription: String? {
        L10n.text("The dictation session ended unexpectedly. Nothing was typed.")
    }
}
