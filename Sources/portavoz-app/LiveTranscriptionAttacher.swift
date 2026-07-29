import ApplicationKit
import Foundation
import PortavozCore
import TranscriptionKit

/// One pinned process runtime plus the composition-owned completion that ends
/// its residency lease. The bridge never knows which concrete model registry
/// backs the handle.
struct LiveTranscriptionRuntime: Sendable {
    let engine: any TranscriptionEngine
    private let completion: @MainActor @Sendable () -> Void

    init(
        engine: any TranscriptionEngine,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        self.engine = engine
        self.completion = completion
    }

    @MainActor
    func finish() {
        completion()
    }
}

/// Recording-scoped bridge that attaches live speech consumers immediately or
/// after the process-wide verified model load completes. Capture owns the
/// bounded producer separately, so this actor can never delay audio writes.
actor LiveTranscriptionAttacher {
    typealias Loader = @MainActor @Sendable () async throws -> LiveTranscriptionRuntime

    nonisolated let feeds: BoundedLiveAudioFeeds

    private let channels: [AudioChannel]
    private let hints: TranscriptionHints
    private let callbacks: StartRecordingLiveCallbacks
    private let telemetry: ResourceWorkloadTelemetry
    private var consumers: [Task<Void, Never>] = []
    private var attachmentTask: Task<Void, Never>?
    private var runtime: LiveTranscriptionRuntime?
    private var active = false
    private var requiresRecovery: Bool

    init(
        channels: [AudioChannel],
        hints: TranscriptionHints,
        callbacks: StartRecordingLiveCallbacks,
        initialRuntime: LiveTranscriptionRuntime?,
        capacityPerChannel: Int = 128,
        telemetry: ResourceWorkloadTelemetry = .disabled
    ) {
        self.channels = Array(Set(channels))
        self.hints = hints
        self.callbacks = callbacks
        self.telemetry = telemetry
        runtime = initialRuntime
        requiresRecovery = initialRuntime == nil
        feeds = BoundedLiveAudioFeeds(
            channels: channels,
            capacityPerChannel: capacityPerChannel)
    }

    func recordingDidStart(
        loader: @escaping Loader
    ) {
        active = true
        if let runtime {
            attach(runtime.engine)
            callbacks.liveTranscription(.available)
            return
        }

        callbacks.liveTranscription(.preparing)
        attachmentTask = Task { [weak self] in
            do {
                let runtime = try await loader()
                do {
                    try Task.checkCancellation()
                } catch {
                    await runtime.finish()
                    throw error
                }
                guard let self else {
                    await runtime.finish()
                    return
                }
                await self.attachLoaded(runtime)
            } catch is CancellationError {
                // Stop cancels this recording's waiter only. The shared model
                // task remains process-owned and can serve the next session;
                // a lease returned after cancellation is completed above.
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
        let runtime = runtime
        self.runtime = nil
        await runtime?.finish()
        return requiresRecovery
    }

    private func attachLoaded(_ runtime: LiveTranscriptionRuntime) async {
        guard active else {
            await runtime.finish()
            return
        }
        attachmentTask = nil
        self.runtime = runtime
        attach(runtime.engine)
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
            let telemetry = telemetry
            consumers.append(Task { [weak self] in
                let span = telemetry.begin(ResourceWorkloadDescriptor(
                    workloadClass: .liveInteractive,
                    kind: .liveTranscription,
                    operation: .execute))
                do {
                    for try await segment in segments {
                        guard let self else {
                            telemetry.finish(span, outcome: .cancelled)
                            return
                        }
                        await self.callbacks.caption(segment)
                    }
                    telemetry.finish(span, outcome: .completed)
                } catch is CancellationError {
                    telemetry.finish(span, outcome: .cancelled)
                } catch {
                    telemetry.finish(span, outcome: .failed)
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
