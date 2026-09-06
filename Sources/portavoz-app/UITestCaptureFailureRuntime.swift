import ApplicationKit
import AudioCaptureKit
import DiarizationKit
import Foundation
import PortavozCore

/// Opt-in disposable real-session fixture: no hardware, models, or private PCM.
/// Exercises native CAF publication and the production Stop/storage adapter.
struct UITestCaptureFailureRuntime: StartRecordingRuntime {
    let audioRoot: URL

    func prepare(preferences: StartRecordingPreferencesSnapshot) async throws -> StartRecordingPreparedRuntime {
        StartRecordingPreparedRuntime(channels: [.microphone, .system], tappedMeetingApps: [],
                                      liveTranscriptionAvailable: false)
    }

    func startCapture(_ request: StartRecordingCaptureRequest) async throws -> any StartRecordingSession {
        let session = RecordingSession(outputDirectory: audioRoot.appendingPathComponent(request.audioDirectory))
        try await session.start(
            sources: [UITestCaptureSource(channel: .microphone), UITestCaptureSource(channel: .system)],
            onLevel: request.callbacks.level, onHealthEvent: request.callbacks.health)
        return UITestCaptureFailureSession(session: session)
    }

    func cancelPreparation() async {}
    func scheduleIdleRelease() async {}
}

private struct UITestCaptureSource: AudioCaptureSource {
    let channel: AudioChannel
    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        let pair = AsyncThrowingStream<AudioChunk, Error>.makeStream()
        // Two seconds keeps the prefix above the existing >1 s recovery-job
        // admission floor, so Stop follows the normal persisted-detail route.
        pair.continuation.yield(AudioChunk(channel: channel, samples: Array(repeating: 0.2, count: 96_000),
                                           sampleRate: 48_000, timestamp: 0))
        if channel == .microphone {
            pair.continuation.finish(throwing: AudioCaptureError.unsupportedFormat)
        } else {
            pair.continuation.finish()
        }
        return pair.stream
    }
    func stop() async {}
}

private actor UITestCaptureFailureSession: StartRecordingSession {
    let session: RecordingSession
    init(session: RecordingSession) { self.session = session }
    func stop() async -> StopRecordingCapture {
        StopRecordingCapture(await session.stop(), transcriptRequiresRecovery: true)
    }
    func voiceprint() async -> Voiceprint? { nil }
    func cancelVoiceprintRead() async {}
    nonisolated func setMicrophoneMuted(_ value: Bool) {}
}
