import ApplicationKit
import AudioCaptureKit
import DiarizationKit
import Foundation

extension AppServices {
    func localVoiceIdentityStatus() async throws -> Voiceprint? {
        guard case .status(let voiceprint) = try await localVoiceIdentity.execute(.status)
        else { return nil }
        return voiceprint
    }

    func enrollLocalVoice(
        from sample: LocalVoiceSample,
        progress: @escaping LocalVoiceEnrollmentProgressHandler = { _ in }
    ) async throws -> Voiceprint {
        guard case .enrolled(let voiceprint) = try await localVoiceIdentity.execute(
            .enrollSample(sample, progress: progress))
        else { throw ManageLocalVoiceIdentityError.unsupportedEnrollmentSource }
        return voiceprint
    }

    func recordAndEnrollLocalVoice(
        seconds: Int,
        mode: LocalVoiceCaptureMode,
        progress: @escaping LocalVoiceEnrollmentProgressHandler = { _ in }
    ) async throws -> Voiceprint {
        guard case .enrolled(let voiceprint) = try await localVoiceIdentity.execute(
            .recordAndEnroll(seconds: seconds, mode: mode, progress: progress))
        else { throw ManageLocalVoiceIdentityError.unsupportedEnrollmentSource }
        return voiceprint
    }

    func deleteLocalVoiceIdentity() async throws {
        _ = try await localVoiceIdentity.execute(.delete)
    }

    private var localVoiceIdentity: ManageLocalVoiceIdentity {
        ManageLocalVoiceIdentity(
            sampleCapture: AppLocalVoiceSampleCapture(),
            identities: AppLocalVoiceIdentityStore(
                storage: voiceprintStore,
                disabled: ProcessInfo.processInfo.arguments.contains("-use-temp-store"),
                invalidate: { @MainActor [weak self] in self?.invalidateDiarizer() }),
            sampleExtractor: AppLocalVoiceSampleExtractor(
                loadDiarizer: { @MainActor [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.loadDiarizerIfNeeded()
                }))
    }
}

private struct AppLocalVoiceIdentityStore: LocalVoiceIdentityStoring {
    let storage: VoiceprintStore
    let disabled: Bool
    let invalidate: @MainActor @Sendable () -> Void

    func loadVoiceIdentity() async throws -> Voiceprint? {
        guard !disabled else { return nil }
        let storage = storage
        return try await Task.detached(priority: .utility) {
            try storage.load()
        }.value
    }

    func saveVoiceIdentity(_ voiceprint: Voiceprint) async throws {
        guard !disabled else { return }
        let storage = storage
        try await Task.detached(priority: .utility) {
            try storage.save(voiceprint)
        }.value
        await invalidate()
    }

    func deleteVoiceIdentity() async throws {
        guard !disabled else { return }
        let storage = storage
        try await Task.detached(priority: .utility) {
            try storage.delete()
        }.value
        await invalidate()
    }
}

private struct AppLocalVoiceSampleExtractor: LocalVoiceSampleIdentityExtracting {
    let loadDiarizer: @MainActor @Sendable () async throws -> PyannoteDiarizer

    func extractVoiceIdentity(from sample: LocalVoiceSample) async throws -> Voiceprint {
        let diarizer = try await loadDiarizer()
        return try await diarizer.extractVoiceprint(
            fromSamples: sample.samples,
            sampleRate: sample.sampleRate)
    }
}

private struct AppLocalVoiceSampleCapture: LocalVoiceSampleCapturing {
    func captureVoiceSample(
        seconds: Int,
        mode: LocalVoiceCaptureMode,
        progress: @escaping LocalVoiceEnrollmentProgressHandler
    ) async throws -> LocalVoiceSample {
        let microphone = MicrophoneSource(voiceProcessing: mode == .echoCancelled)
        let stream = try await microphone.start()
        var samples: [Float] = []
        var sampleRate = 16_000.0
        let clock = ContinuousClock()
        let startedAt = clock.now
        var lastRemaining = seconds
        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                samples.append(contentsOf: chunk.samples)
                sampleRate = chunk.sampleRate
                let elapsed = Self.seconds(in: startedAt.duration(to: clock.now))
                let remaining = max(0, seconds - Int(elapsed))
                if remaining != lastRemaining {
                    lastRemaining = remaining
                    await progress(.capturing(secondsRemaining: remaining))
                }
                if elapsed >= Double(seconds) { break }
            }
            await microphone.stop()
            return LocalVoiceSample(samples: samples, sampleRate: sampleRate)
        } catch {
            await microphone.stop()
            throw error
        }
    }

    private static func seconds(in duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
