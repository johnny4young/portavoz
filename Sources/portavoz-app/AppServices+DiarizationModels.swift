import DiarizationKit
import Foundation
import PortavozCore

extension AppServices {
    struct DiarizationRuntimeLoad {
        let generation: UUID
        let ticket: ResourceModelLoadTicket
        let task: Task<PyannoteDiarizationRuntime, Error>
    }

    struct DiarizationRuntimeLease: Sendable {
        let runtime: PyannoteDiarizationRuntime
        fileprivate let residency: ResourceModelUseLease
    }

    /// Borrows the process-wide verified Core ML model pair. Each operation
    /// must create a fresh diarizer session because speaker clustering state
    /// belongs to one meeting, not to the reusable weights.
    func acquireDiarizationRuntime(
        workloadClass: ResourceWorkloadClass = .userInitiated
    ) async throws -> DiarizationRuntimeLease {
        enginesIdleGeneration += 1
        if let runtime = try residentDiarizationRuntime() {
            return try checkedDiarizationRuntime(runtime)
        }
        if let active = diarizationRuntimeLoad {
            let runtime = try await finishDiarizationRuntimeLoad(active)
            return try checkedDiarizationRuntime(runtime)
        }

        modelsState = .downloading(L10n.text("Preparing models…"))
        guard let ticket = modelResidencyLedger.beginLoad(.speakerDiarization) else {
            throw DiarizationRuntimeError.inconsistentResidency
        }
        let telemetry = workloadTelemetry
        let store = modelStore
        let task = Task { @MainActor in
            try await telemetry.measure(ResourceWorkloadDescriptor(
                workloadClass: workloadClass,
                kind: .speakerDiarization,
                operation: .load)
            ) {
                try await PyannoteDiarizationRuntime.loadRecommended(
                    store: store
                ) { progress in
                    let percent = Int(progress.fraction * 100)
                    Task { @MainActor [weak self] in
                        self?.modelsState = .downloading(
                            L10n.format(
                                "Downloading diarization model… %d%%",
                                percent))
                    }
                }
            }
        }
        let load = DiarizationRuntimeLoad(
            generation: UUID(),
            ticket: ticket,
            task: task)
        diarizationRuntimeLoad = load
        let runtime = try await finishDiarizationRuntimeLoad(load)
        return try checkedDiarizationRuntime(runtime)
    }

    func makeDiarizer(
        from runtime: DiarizationRuntimeLease,
        voiceprint: Voiceprint? = nil
    ) -> PyannoteDiarizer {
        runtime.runtime.makeDiarizer(voiceprint: voiceprint)
    }

    @discardableResult
    func finishDiarizationRuntime(
        _ runtime: DiarizationRuntimeLease
    ) -> Bool {
        modelResidencyLedger.finishUse(runtime.residency)
    }

    /// Reads the current optional identity away from MainActor. Callers keep
    /// this value with the fresh session for the complete operation.
    func currentDiarizationVoiceprint() async -> Voiceprint? {
        let store = voiceprintStore
        return await Task.detached(priority: .utility) {
            try? store.load()
        }.value
    }

    /// Drops only idle Core ML weights; verified files remain installed.
    @discardableResult
    func releaseDiarizationRuntime() -> Bool {
        guard diarizationRuntimeLoad == nil else { return false }
        guard diarizationRuntime != nil else {
            return modelResidencyLedger.record(
                for: .speakerDiarization
            ).status == .unloaded
        }
        guard let ticket = modelResidencyLedger.beginRelease(
            .speakerDiarization)
        else {
            return false
        }
        let retainedRuntime = diarizationRuntime
        let span = workloadTelemetry.begin(ResourceWorkloadDescriptor(
            workloadClass: .maintenance,
            kind: .speakerDiarization,
            operation: .release))
        diarizationRuntime = nil
        workloadTelemetry.finish(span, outcome: .completed)
        guard modelResidencyLedger.finishRelease(ticket) else {
            diarizationRuntime = retainedRuntime
            _ = modelResidencyLedger.cancelRelease(ticket)
            return false
        }
        settleModelsState()
        return true
    }

    private func finishDiarizationRuntimeLoad(
        _ load: DiarizationRuntimeLoad
    ) async throws -> DiarizationRuntimeLease {
        do {
            let runtime = try await load.task.value
            guard diarizationRuntimeLoad?.generation == load.generation else {
                guard let resident = try residentDiarizationRuntime() else {
                    throw CancellationError()
                }
                return resident
            }
            guard modelResidencyLedger.finishLoad(
                load.ticket,
                measuredFootprintBytes: nil)
            else {
                diarizationRuntimeLoad = nil
                _ = modelResidencyLedger.failLoad(load.ticket)
                throw DiarizationRuntimeError.inconsistentResidency
            }
            diarizationRuntimeLoad = nil
            diarizationRuntime = runtime
            settleModelsState()
            guard let resident = try residentDiarizationRuntime() else {
                _ = releaseDiarizationRuntime()
                throw DiarizationRuntimeError.inconsistentResidency
            }
            return resident
        } catch {
            if diarizationRuntimeLoad?.generation == load.generation {
                diarizationRuntimeLoad = nil
                _ = modelResidencyLedger.failLoad(load.ticket)
                modelsState = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    private func residentDiarizationRuntime() throws
        -> DiarizationRuntimeLease? {
        guard let diarizationRuntime else { return nil }
        guard let residency = modelResidencyLedger.beginUse(
            .speakerDiarization)
        else {
            throw DiarizationRuntimeError.inconsistentResidency
        }
        return DiarizationRuntimeLease(
            runtime: diarizationRuntime,
            residency: residency)
    }

    private func checkedDiarizationRuntime(
        _ runtime: DiarizationRuntimeLease
    ) throws -> DiarizationRuntimeLease {
        do {
            try Task.checkCancellation()
            return runtime
        } catch {
            _ = finishDiarizationRuntime(runtime)
            scheduleRecordingEnginesRelease()
            throw error
        }
    }
}

private enum DiarizationRuntimeError: Error {
    case inconsistentResidency
}
