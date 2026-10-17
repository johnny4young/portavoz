import Foundation
import ModelStoreKit
import PortavozCore
import TranscriptionKit

extension AppServices {
    /// Explicit readiness for workflows that truly need both models.
    func loadEnginesIfNeeded() async throws {
        // Warm-up is idle work too; without a deadline it stays resident forever.
        defer { scheduleRecordingEnginesRelease() }
        let liveSpeech = try await acquireLiveSpeechRuntime()
        defer { _ = finishLiveSpeechRuntime(liveSpeech) }
        let diarization = try await acquireDiarizationRuntime()
        defer { _ = finishDiarizationRuntime(diarization) }
        modelsState = .ready
    }

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
    /// on every outcome. One checkpoint is resident at a time: a caller that
    /// `acceptsResident` (dictation) borrows the other one while it is in use,
    /// and every other caller waits for it to go idle, then swaps.
    func acquireLiveSpeechRuntime(
        workloadClass: ResourceWorkloadClass = .liveInteractive,
        checkpoint: ParakeetCheckpoint = .v3,
        acceptsResident: Bool = false
    ) async throws -> LiveSpeechRuntimeLease {
        // A caller cancelled before admission must not begin a process-owned
        // model load that can continue downloading after the session is gone.
        try Task.checkCancellation()
        modelIdleReleaseScheduler.cancel(.recording)
        while true {
            let plan = LiveSpeechCheckpointPlan(
                requested: checkpoint, resident: transcriber?.checkpoint,
                residentInUse: modelResidencyLedger.record(for: .liveSpeech).activeUseCount > 0,
                loading: liveSpeechRuntimeLoad != nil, acceptsResident: acceptsResident)
            switch plan {
            case .useResident:
                if let runtime = try residentLiveSpeechRuntime() {
                    return try checkedLiveSpeechRuntime(runtime)
                }
            case .awaitLoad:
                guard let active = liveSpeechRuntimeLoad else { continue }
                let runtime = try await finishLiveSpeechRuntimeLoad(active)
                if acceptsResident || runtime.engine.checkpoint == checkpoint {
                    return try checkedLiveSpeechRuntime(runtime)
                }
                _ = finishLiveSpeechRuntime(runtime)
            case .swap:
                if !releaseLiveSpeechRuntime() { try await Task.sleep(for: .milliseconds(100)) }
            case .waitForIdle:
                try await Task.sleep(for: .milliseconds(100))
            case .load:
                let runtime = try await finishLiveSpeechRuntimeLoad(
                    beginLiveSpeechRuntimeLoad(checkpoint, workloadClass: workloadClass))
                return try checkedLiveSpeechRuntime(runtime)
            }
        }
    }

    private func beginLiveSpeechRuntimeLoad(
        _ checkpoint: ParakeetCheckpoint, workloadClass: ResourceWorkloadClass
    ) throws -> LiveSpeechRuntimeLoad {
        modelsState = .downloading(L10n.text("Preparing models…"))
        guard let ticket = modelResidencyLedger.beginLoad(.liveSpeech) else {
            throw LiveSpeechRuntimeError.inconsistentResidency
        }
        let telemetry = workloadTelemetry
        let store = modelStore
        let lifecycle = modelLifecycle
        let task = Task { @MainActor [weak self] in
            try await telemetry.measure(ResourceWorkloadDescriptor(
                workloadClass: workloadClass,
                kind: .liveTranscription,
                operation: .load)
            ) {
                if checkpoint == .ultra {
                    // Only an explicit Settings choice installs Ultra; never download it here.
                    guard let installed = await lifecycle.installation(for: ModelCatalog.parakeetUltra) else {
                        throw LiveSpeechRuntimeError.checkpointNotInstalled
                    }
                    return try await ParakeetEngine.load(
                        fromVerifiedDirectory: installed.directory, checkpoint: .ultra)
                }
                return try await ParakeetEngine.loadRecommended(store: store) { progress in
                    let percent = Int(progress.fraction * 100)
                    Task { @MainActor in
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
        return load
    }

    /// Claims a hot runtime without starting model preparation. Recording
    /// preparation uses this synchronous path so capture can remain audio-first.
    func acquireResidentLiveSpeechRuntime() throws -> LiveSpeechRuntimeLease? {
        modelIdleReleaseScheduler.cancel(.recording)
        // Recording never borrows the dictation-only checkpoint.
        guard transcriber?.checkpoint == .v3, let runtime = try residentLiveSpeechRuntime() else { return nil }
        return try checkedLiveSpeechRuntime(runtime)
    }

    @discardableResult
    func finishLiveSpeechRuntime(_ runtime: LiveSpeechRuntimeLease) -> Bool {
        modelResidencyLedger.finishUse(runtime.residency)
    }

    func liveTranscriptionRuntime(
        _ runtime: LiveSpeechRuntimeLease
    ) -> LiveTranscriptionRuntime {
        let engine = benchLiveWorkObserver.map(runtime.engine.observingLiveWork) ?? runtime.engine
        return LiveTranscriptionRuntime(engine: engine) { [weak self] in
            guard let self else { return }
            _ = self.finishLiveSpeechRuntime(runtime)
            self.scheduleRecordingEnginesRelease()
        }
    }

    /// Live consumers borrow a transcription engine and its release together.
    /// Batch/maintenance clients keep the concrete Parakeet lease; neither
    /// dictation nor recording needs to know which model owns a live engine.
    func acquireLiveTranscriptionRuntime(
        for purpose: LiveSpeechPurpose = .meeting
    ) async throws -> LiveTranscriptionRuntime {
        if purpose.selectedEngine(in: defaults) == .appleSpeech {
            guard #available(macOS 26.0, *) else {
                throw TranscriptionError.engineUnavailable(
                    "Apple Speech requires macOS Tahoe or later")
            }
            let engine = try await SpeechAnalyzerLiveEngine.acquireInstalled(
                language: purpose.language(in: defaults))
            return LiveTranscriptionRuntime(engine: engine) {}
        }
        guard purpose == .dictation else {
            return liveTranscriptionRuntime(try await acquireLiveSpeechRuntime())
        }
        return liveTranscriptionRuntime(try await acquireLiveSpeechRuntime(
            checkpoint: await dictationCheckpoint(), acceptsResident: true))
    }

    /// Capture must not await a model load before writing audio. A missing hot
    /// engine is attached later through the same live lease boundary.
    func acquireResidentLiveTranscriptionRuntime() throws -> LiveTranscriptionRuntime? {
        // Apple readiness is asynchronous. Capture starts audio-first and the
        // verified loader hot-attaches; early audio gets durable recovery.
        if LiveSpeechPurpose.meeting.selectedEngine(in: defaults) == .appleSpeech { return nil }
        return try acquireResidentLiveSpeechRuntime().map(liveTranscriptionRuntime)
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

/// What one caller does with the single resident live-speech runtime.
enum LiveSpeechCheckpointPlan: Equatable {
    case useResident
    case awaitLoad
    case swap
    case waitForIdle
    case load

    init(
        requested: ParakeetCheckpoint, resident: ParakeetCheckpoint?, residentInUse: Bool,
        loading: Bool, acceptsResident: Bool
    ) {
        if loading {
            self = .awaitLoad
        } else if let resident {
            if resident == requested || (acceptsResident && residentInUse) {
                self = .useResident
            } else {
                self = residentInUse ? .waitForIdle : .swap
            }
        } else {
            self = .load
        }
    }
}

private enum LiveSpeechRuntimeError: Error {
    case inconsistentResidency
    case checkpointNotInstalled
}
