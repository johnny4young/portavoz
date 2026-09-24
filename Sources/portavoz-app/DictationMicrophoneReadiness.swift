import AudioCaptureKit
import Foundation
import PortavozCore

/// Session-owned first-frame admission and its bounded startup wait. Native
/// cleanup stays with the controller; this owner cannot release model leases.
@MainActor
final class DictationMicrophoneReadiness {
    private(set) var firstFrameAt: Date?
    private var accepting = true
    private var deadlineTask: Task<Void, Never>?
    private let now: () -> Date
    private let onReady: () -> Void
    private let onFailure: (Failure) -> Void

    enum Failure: Error {
        case permissionRequired
        case noAudio
        case invalidAudio

        var message: String {
            switch self {
            case .permissionRequired:
                L10n.text("Allow microphone access in System Settings, then try dictation again.")
            case .noAudio:
                L10n.text("No microphone audio arrived. Check the microphone in Audio settings and try again.")
            case .invalidAudio:
                L10n.text("The microphone sent unusable audio. Check the input device and try again.")
            }
        }
    }

    static func preparationMessage(for error: Error) -> String? {
        if let failure = error as? Failure { return failure.message }
        if case AudioCaptureError.noInputDevice = error {
            return L10n.text("No microphone is available. Choose an input in Audio settings and try again.")
        }
        return nil
    }

    init(now: @escaping () -> Date, onReady: @escaping () -> Void, onFailure: @escaping (Failure) -> Void) {
        self.now = now
        self.onReady = onReady
        self.onFailure = onFailure
    }

    func beginDeadline(wait: @escaping @Sendable () async throws -> Void) {
        deadlineTask = Task { [weak self] in
            do { try await wait() } catch { return }
            guard !Task.isCancelled, let self, accepting, firstFrameAt == nil else { return }
            reject(.noAudio)
        }
    }

    func finish() {
        accepting = false
        deadlineTask?.cancel()
        deadlineTask = nil
    }

    private func accept() -> Bool {
        guard accepting else { return false }
        if firstFrameAt == nil {
            firstFrameAt = now()
            deadlineTask?.cancel()
            deadlineTask = nil
            onReady()
        }
        return true
    }

    private func reject(_ failure: Failure) {
        guard accepting else { return }
        finish()
        onFailure(failure)
    }

    private func rejectIfNoFirstFrame() {
        guard firstFrameAt == nil else { return }
        reject(.noAudio)
    }

    func pump(
        stream: AsyncThrowingStream<AudioChunk, Error>,
        feed: AsyncStream<AudioChunk>.Continuation,
        updateMeter: @escaping @MainActor @Sendable (Float) -> Void
    ) -> Task<Void, Never> {
        Task.detached { [self] in
            do {
                for try await chunk in stream {
                    try Task.checkCancellation()
                    guard !chunk.samples.isEmpty else { continue }
                    guard chunk.channel == .microphone, chunk.sampleRate.isFinite, chunk.sampleRate > 0 else {
                        await reject(.invalidAudio)
                        break
                    }
                    var peak: Float = 0
                    for sample in chunk.samples {
                        guard sample.isFinite else {
                            await reject(.invalidAudio)
                            feed.finish()
                            return
                        }
                        peak = max(peak, abs(sample))
                    }
                    guard await accept(), !Task.isCancelled else { break }
                    feed.yield(chunk)
                    await updateMeter(peak)
                }
            } catch {}
            // A device can close or fail its stream before the deadline fires.
            // Finishing the feed alone would make the controller complete an
            // apparently successful, empty dictation without recovery guidance.
            await rejectIfNoFirstFrame()
            feed.finish()
        }
    }
}
