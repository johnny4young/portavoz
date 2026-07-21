import ApplicationKit
import Foundation
import PortavozCore
import TranscriptionKit

/// Recording-scoped bridge that attaches live speech consumers immediately or
/// after the process-wide verified model load completes. Capture owns the
/// bounded producer separately, so this actor can never delay audio writes.
actor LiveTranscriptionAttacher {
    typealias Loader = @MainActor @Sendable () async throws -> any TranscriptionEngine

    nonisolated let feeds: BoundedLiveAudioFeeds

    private let channels: [AudioChannel]
    private let hints: TranscriptionHints
    private let callbacks: StartRecordingLiveCallbacks
    private var consumers: [Task<Void, Never>] = []
    private var attachmentTask: Task<Void, Never>?
    private var active = false
    private var requiresRecovery: Bool

    init(
        channels: [AudioChannel],
        hints: TranscriptionHints,
        callbacks: StartRecordingLiveCallbacks,
        initialTranscriberAvailable: Bool,
        capacityPerChannel: Int = 128
    ) {
        self.channels = Array(Set(channels))
        self.hints = hints
        self.callbacks = callbacks
        requiresRecovery = !initialTranscriberAvailable
        feeds = BoundedLiveAudioFeeds(
            channels: channels,
            capacityPerChannel: capacityPerChannel)
    }

    func recordingDidStart(
        initialTranscriber: (any TranscriptionEngine)?,
        loader: @escaping Loader
    ) {
        active = true
        if let initialTranscriber {
            attach(initialTranscriber)
            callbacks.liveTranscription(.available)
            return
        }

        callbacks.liveTranscription(.preparing)
        attachmentTask = Task { [weak self] in
            do {
                let transcriber = try await loader()
                try Task.checkCancellation()
                await self?.attachLoaded(transcriber)
            } catch is CancellationError {
                // Stop cancels this recording's waiter only. The shared model
                // task remains process-owned and can serve the next session.
            } catch {
                await self?.deferredAttachmentFailed()
            }
        }
    }

    func finish() async -> Bool {
        active = false
        attachmentTask?.cancel()
        attachmentTask = nil
        feeds.finish()
        let pending = consumers
        consumers = []
        for consumer in pending {
            await consumer.value
        }
        return requiresRecovery
    }

    private func attachLoaded(_ transcriber: any TranscriptionEngine) {
        guard active else { return }
        attachmentTask = nil
        attach(transcriber)
        callbacks.liveTranscription(.available)
    }

    private func deferredAttachmentFailed() {
        guard active else { return }
        attachmentTask = nil
        requiresRecovery = true
        callbacks.liveTranscription(.failed)
    }

    private func attach(_ transcriber: any TranscriptionEngine) {
        for channel in channels {
            guard let stream = feeds.stream(for: channel) else { continue }
            let segments = transcriber.transcribe(stream, hints: hints)
            consumers.append(Task { [weak self] in
                do {
                    for try await segment in segments {
                        guard let self else { return }
                        await self.callbacks.caption(segment)
                    }
                } catch {
                    await self?.liveLaneFailed()
                }
            })
        }
    }

    private func liveLaneFailed() {
        guard active else { return }
        requiresRecovery = true
        callbacks.liveTranscription(.failed)
    }
}
