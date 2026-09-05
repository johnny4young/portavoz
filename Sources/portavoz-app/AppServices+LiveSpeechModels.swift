import Foundation
import PortavozCore
import TranscriptionKit

extension AppServices {
    struct LiveSpeechRuntimeLoad {
        let generation: UUID
        let ticket: ResourceModelLoadTicket
        let task: Task<ParakeetEngine, Error>
    }

    struct LiveSpeechRuntimeLease: Sendable {
        let engine: ParakeetEngine
        fileprivate let residency: ResourceModelUseLease
    }

    /// Borrows the process-wide first-pass speech runtime. Callers retain the
    /// returned lease for their complete live or batch operation and finish it
    /// on every outcome.
    func acquireLiveSpeechRuntime(
        workloadClass: ResourceWorkloadClass = .liveInteractive
    ) async throws -> LiveSpeechRuntimeLease {
        enginesIdleGeneration += 1
        if let runtime = try residentLiveSpeechRuntime() {
            return try checkedLiveSpeechRuntime(runtime)
        }
        if let active = liveSpeechRuntimeLoad {
            let runtime = try await finishLiveSpeechRuntimeLoad(active)
            return try checkedLiveSpeechRuntime(runtime)
        }

        modelsState = .downloading(L10n.text("Preparing models…"))
        guard let ticket = modelResidencyLedger.beginLoad(.liveSpeech) else {
            throw LiveSpeechRuntimeError.inconsistentResidency
        }
        let telemetry = workloadTelemetry
        let store = modelStore
        let task = Task { @MainActor in
            try await telemetry.measure(ResourceWorkloadDescriptor(
                workloadClass: workloadClass,
                kind: .liveTranscription,
                operation: .load)
            ) {
                try await ParakeetEngine.loadRecommended(store: store) { progress in
                    let percent = Int(progress.fraction * 100)
                    Task { @MainActor [weak self] in
                        self?.modelsState = .downloading(
                            L10n.format(
                                "Downloading transcription model… %d%%",
                                percent))
                    }
                }
            }
        }
        let load = LiveSpeechRuntimeLoad(
            generation: UUID(),
            ticket: ticket,
            task: task)
        liveSpeechRuntimeLoad = load
        let runtime = try await finishLiveSpeechRuntimeLoad(load)
        return try checkedLiveSpeechRuntime(runtime)
    }

    /// Claims a hot runtime without starting model preparation. Recording
    /// preparation uses this synchronous path so capture can remain audio-first.
    func acquireResidentLiveSpeechRuntime() throws -> LiveSpeechRuntimeLease? {
        enginesIdleGeneration += 1
        guard let runtime = try residentLiveSpeechRuntime() else { return nil }
        return try checkedLiveSpeechRuntime(runtime)
    }

    @discardableResult
    func finishLiveSpeechRuntime(_ runtime: LiveSpeechRuntimeLease) -> Bool {
        modelResidencyLedger.finishUse(runtime.residency)
    }

    func liveTranscriptionRuntime(
        _ runtime: LiveSpeechRuntimeLease
    ) -> LiveTranscriptionRuntime {
        LiveTranscriptionRuntime(engine: runtime.engine) { [weak self] in
            guard let self else { return }
            _ = self.finishLiveSpeechRuntime(runtime)
            self.scheduleRecordingEnginesRelease()
        }
    }

    /// Drops only idle model weights; verified assets remain installed.
    @discardableResult
    func releaseLiveSpeechRuntime() -> Bool {
        guard liveSpeechRuntimeLoad == nil else { return false }
        guard transcriber != nil else {
            return modelResidencyLedger.record(for: .liveSpeech).status == .unloaded
        }
        guard let ticket = modelResidencyLedger.beginRelease(.liveSpeech) else {
            return false
        }
        let retainedRuntime = transcriber
        let span = workloadTelemetry.begin(ResourceWorkloadDescriptor(
            workloadClass: .maintenance,
            kind: .liveTranscription,
            operation: .release))
        transcriber = nil
        workloadTelemetry.finish(span, outcome: .completed)
        guard modelResidencyLedger.finishRelease(ticket) else {
            transcriber = retainedRuntime
            _ = modelResidencyLedger.cancelRelease(ticket)
            return false
        }
        settleModelsState()
        return true
    }

    private func finishLiveSpeechRuntimeLoad(
        _ load: LiveSpeechRuntimeLoad
    ) async throws -> LiveSpeechRuntimeLease {
        do {
            let engine = try await load.task.value
            guard liveSpeechRuntimeLoad?.generation == load.generation else {
                guard let runtime = try residentLiveSpeechRuntime() else {
                    throw CancellationError()
                }
                return runtime
            }
            guard modelResidencyLedger.finishLoad(
                load.ticket,
                measuredFootprintBytes: nil)
            else {
                liveSpeechRuntimeLoad = nil
                _ = modelResidencyLedger.failLoad(load.ticket)
                throw LiveSpeechRuntimeError.inconsistentResidency
            }
            liveSpeechRuntimeLoad = nil
            transcriber = engine
            settleModelsState()
            guard let runtime = try residentLiveSpeechRuntime() else {
                _ = releaseLiveSpeechRuntime()
                throw LiveSpeechRuntimeError.inconsistentResidency
            }
            return runtime
        } catch {
            if liveSpeechRuntimeLoad?.generation == load.generation {
                liveSpeechRuntimeLoad = nil
                _ = modelResidencyLedger.failLoad(load.ticket)
                modelsState = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    private func residentLiveSpeechRuntime() throws -> LiveSpeechRuntimeLease? {
        guard let transcriber else { return nil }
        guard let residency = modelResidencyLedger.beginUse(.liveSpeech) else {
            throw LiveSpeechRuntimeError.inconsistentResidency
        }
        return LiveSpeechRuntimeLease(
            engine: transcriber,
            residency: residency)
    }

    private func checkedLiveSpeechRuntime(
        _ runtime: LiveSpeechRuntimeLease
    ) throws -> LiveSpeechRuntimeLease {
        do {
            try Task.checkCancellation()
            return runtime
        } catch {
            _ = finishLiveSpeechRuntime(runtime)
            scheduleRecordingEnginesRelease()
            throw error
        }
    }
}

private enum LiveSpeechRuntimeError: Error {
    case inconsistentResidency
}
