import Foundation
import ModelStoreKit
import PortavozCore
import TranscriptionKit

extension AppServices {
    enum WhisperPreparationState: Equatable {
        case idle
        case preparing(
            variantID: String,
            size: String,
            percent: Int,
            isDownloading: Bool)
        case ready(variantID: String)
        case failed(variantID: String, message: String)

        var isPreparing: Bool {
            if case .preparing = self { return true }
            return false
        }
    }

    struct WhisperVariant: Identifiable {
        let id: String
        let compact: Bool
        let downloaded: Bool
        /// On-disk bytes if complete, otherwise the expected model size.
        let bytes: Int64

        var accessibilitySuffix: String { compact ? "compact" : "turbo" }
    }

    struct WhisperPreparation {
        let generation: UUID
        let descriptorID: String
        let task: Task<WhisperEngine.PreparedModel, Error>
    }

    struct WhisperRuntimeLoad {
        let generation: UUID
        let descriptorID: String
        let ticket: ResourceModelLoadTicket
        let task: Task<WhisperEngine, Error>
    }

    struct WhisperRuntimeLease {
        let engine: WhisperEngine
        let descriptorID: String
        fileprivate let residency: ResourceModelUseLease
    }

    typealias WhisperPreparationObserver =
        @MainActor @Sendable (_ size: String, _ percent: Int, _ isDownloading: Bool) -> Void

    /// The D7 quality re-pass engine. Refine and Import join the same verified
    /// preparation that Settings can start explicitly in the background.
    func acquireWhisperRuntime(
        descriptor requestedDescriptor: ModelDescriptor? = nil,
        workloadClass: ResourceWorkloadClass = .userInitiated,
        progress: @escaping @MainActor (String) -> Void,
        preparationProgress: WhisperPreparationObserver? = nil
    ) async throws -> WhisperRuntimeLease {
        let descriptor = requestedDescriptor ?? Self.preferredWhisperDescriptor()
        whisperIdleGeneration += 1
        if let runtime = try residentWhisperRuntime(descriptorID: descriptor.id) {
            return runtime
        }
        try await admitModelRuntimeLoad(.qualitySpeech)

        let prepared = try await preparedWhisperModel(
            descriptor,
            workloadClass: workloadClass,
            observer: preparationProgress)
        progress(L10n.text("Loading Whisper…"))

        if let runtime = try residentWhisperRuntime(descriptorID: descriptor.id) {
            return runtime
        }
        if let active = whisperRuntimeLoad {
            guard active.descriptorID == descriptor.id else {
                throw WhisperRuntimeError.variantInUse
            }
            return try await finishWhisperRuntimeLoad(active)
        }
        if whisper != nil, !releaseWhisper() {
            throw WhisperRuntimeError.variantInUse
        }

        guard let ticket = try await beginAdmittedModelRuntimeLoad(
            .qualitySpeech
        ) else {
            throw WhisperRuntimeError.inconsistentResidency
        }
        let telemetry = workloadTelemetry
        let task = Task { @MainActor in
            try await telemetry.measure(
                ResourceWorkloadDescriptor(
                    workloadClass: workloadClass,
                    kind: .qualityTranscription,
                    operation: .load)
            ) {
                try await WhisperEngine.loadPrepared(prepared)
            }
        }
        let load = WhisperRuntimeLoad(
            generation: UUID(),
            descriptorID: descriptor.id,
            ticket: ticket,
            task: task)
        whisperRuntimeLoad = load
        return try await finishWhisperRuntimeLoad(load)
    }

    @discardableResult
    func finishWhisperRuntime(_ runtime: WhisperRuntimeLease) -> Bool {
        modelResidencyLedger.finishUse(runtime.residency)
    }

    /// Starts app-scoped verification and downloads only missing/corrupt
    /// artifacts. Closing Settings does not cancel it; a later Refine joins
    /// the exact same task.
    func prepareWhisperVariant(_ id: String) {
        guard let descriptor = Self.whisperDescriptor(id),
              !whisperPreparationState.isPreparing
        else { return }
        whisperBackgroundPreparation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.whisperBackgroundPreparation = nil }
            _ = try? await self.preparedWhisperModel(
                descriptor,
                workloadClass: .userInitiated,
                observer: nil)
        }
    }

    static func preferredWhisperDescriptor() -> ModelDescriptor {
        UserDefaults.standard.bool(forKey: "whisperCompact")
            ? ModelCatalog.whisperLargeV3_626MB
            : ModelCatalog.whisperLargeV3Turbo
    }

    func whisperVariants() async -> [WhisperVariant] {
        let forcedMissing = ProcessInfo.processInfo.arguments.contains("-use-temp-store")
        if forcedMissing {
            return [
                Self.whisperVariant(
                    ModelCatalog.whisperLargeV3Turbo,
                    compact: false,
                    downloaded: false),
                Self.whisperVariant(
                    ModelCatalog.whisperLargeV3_626MB,
                    compact: true,
                    downloaded: false)
            ]
        }
        async let tokenizer = modelLifecycle.installation(
            for: ModelCatalog.whisperTokenizer)
        async let turbo = modelLifecycle.installation(
            for: ModelCatalog.whisperLargeV3Turbo)
        async let compact = modelLifecycle.installation(
            for: ModelCatalog.whisperLargeV3_626MB)
        let (tokenizerInstallation, turboInstallation, compactInstallation) =
            await (tokenizer, turbo, compact)
        let tokenizerReady = tokenizerInstallation != nil
        return [
            Self.whisperVariant(
                ModelCatalog.whisperLargeV3Turbo,
                compact: false,
                downloaded: tokenizerReady && turboInstallation != nil),
            Self.whisperVariant(
                ModelCatalog.whisperLargeV3_626MB,
                compact: true,
                downloaded: tokenizerReady && compactInstallation != nil)
        ]
    }

    func deleteWhisperVariant(_ id: String) async {
        guard let descriptor = Self.whisperDescriptor(id) else { return }
        if case .preparing(let activeID, _, _, _) = whisperPreparationState,
            activeID == id { return }
        if whisperRuntimeLoad?.descriptorID == id { return }
        if whisperVariantID == id, !releaseWhisper() { return }
        try? await modelLifecycle.remove(descriptor)
        if whisperPreparedModel?.descriptorID == id {
            whisperPreparedModel = nil
        }
        switch whisperPreparationState {
        case .ready(let variantID) where variantID == id:
            whisperPreparationState = .idle
        case .failed(let variantID, _) where variantID == id:
            whisperPreparationState = .idle
        default:
            break
        }
    }

    /// Drops the loaded runtime but never removes the verified files.
    @discardableResult
    func releaseWhisper() -> Bool {
        guard whisperRuntimeLoad == nil else { return false }
        guard whisper != nil else {
            return modelResidencyLedger.record(for: .qualitySpeech).status == .unloaded
        }
        guard let ticket = modelResidencyLedger.beginRelease(.qualitySpeech) else {
            return false
        }
        let retainedRuntime = whisper
        let retainedVariantID = whisperVariantID
        let span = workloadTelemetry.begin(ResourceWorkloadDescriptor(
            workloadClass: .maintenance,
            kind: .qualityTranscription,
            operation: .release))
        whisper = nil
        whisperVariantID = nil
        workloadTelemetry.finish(span, outcome: .completed)
        guard modelResidencyLedger.finishRelease(ticket) else {
            whisper = retainedRuntime
            whisperVariantID = retainedVariantID
            _ = modelResidencyLedger.cancelRelease(ticket)
            return false
        }
        return true
    }

    func scheduleWhisperRelease() {
        whisperIdleGeneration += 1
        let generation = whisperIdleGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard let self, generation == self.whisperIdleGeneration else { return }
            self.releaseWhisper()
        }
    }

    private func finishWhisperRuntimeLoad(
        _ load: WhisperRuntimeLoad
    ) async throws -> WhisperRuntimeLease {
        do {
            let engine = try await load.task.value
            guard whisperRuntimeLoad?.generation == load.generation else {
                guard let runtime = try residentWhisperRuntime(
                    descriptorID: load.descriptorID)
                else {
                    throw CancellationError()
                }
                return runtime
            }
            try await admitModelRuntimeLoad(.qualitySpeech)
            guard whisperRuntimeLoad?.generation == load.generation else {
                guard let runtime = try residentWhisperRuntime(
                    descriptorID: load.descriptorID)
                else {
                    throw CancellationError()
                }
                return runtime
            }
            guard modelResidencyLedger.finishLoad(
                load.ticket,
                measuredFootprintBytes: nil)
            else {
                whisperRuntimeLoad = nil
                _ = modelResidencyLedger.failLoad(load.ticket)
                throw WhisperRuntimeError.inconsistentResidency
            }
            whisperRuntimeLoad = nil
            whisper = engine
            whisperVariantID = load.descriptorID
            guard let runtime = try residentWhisperRuntime(
                descriptorID: load.descriptorID)
            else {
                _ = releaseWhisper()
                throw WhisperRuntimeError.inconsistentResidency
            }
            return runtime
        } catch {
            if whisperRuntimeLoad?.generation == load.generation {
                whisperRuntimeLoad = nil
                _ = modelResidencyLedger.failLoad(load.ticket)
            }
            throw error
        }
    }

    private func residentWhisperRuntime(
        descriptorID: String
    ) throws -> WhisperRuntimeLease? {
        guard let whisper, whisperVariantID == descriptorID else { return nil }
        guard let residency = modelResidencyLedger.beginUse(.qualitySpeech) else {
            throw WhisperRuntimeError.inconsistentResidency
        }
        return WhisperRuntimeLease(
            engine: whisper,
            descriptorID: descriptorID,
            residency: residency)
    }
}

extension AppServices {
    private func preparedWhisperModel(
        _ descriptor: ModelDescriptor,
        workloadClass: ResourceWorkloadClass,
        observer: WhisperPreparationObserver?
    ) async throws -> WhisperEngine.PreparedModel {
        if let whisperPreparedModel,
            whisperPreparedModel.descriptorID == descriptor.id {
            return whisperPreparedModel
        }
        let observerID = observer.map { observer in
            let id = UUID()
            whisperProgressObservers[id] = observer
            if case .preparing(
                let variantID,
                let size,
                let percent,
                let isDownloading) = whisperPreparationState,
                variantID == descriptor.id {
                observer(size, percent, isDownloading)
            }
            return id
        }
        defer {
            if let observerID { whisperProgressObservers[observerID] = nil }
        }

        while let active = whisperPreparation,
              active.descriptorID != descriptor.id {
            _ = try? await finishWhisperPreparation(active)
        }
        if let active = whisperPreparation {
            return try await finishWhisperPreparation(active)
        }

        let generation = UUID()
        let size = Self.whisperSizeLabel(descriptor)
        whisperPreparationState = .preparing(
            variantID: descriptor.id,
            size: size,
            percent: 0,
            isDownloading: false)
        for observer in whisperProgressObservers.values {
            observer(size, 0, false)
        }
        let task = makeWhisperPreparationTask(
            descriptor,
            workloadClass: workloadClass,
            size: size)
        let preparation = WhisperPreparation(
            generation: generation,
            descriptorID: descriptor.id,
            task: task)
        whisperPreparation = preparation
        return try await finishWhisperPreparation(preparation)
    }

    private func makeWhisperPreparationTask(
        _ descriptor: ModelDescriptor,
        workloadClass: ResourceWorkloadClass,
        size: String
    ) -> Task<WhisperEngine.PreparedModel, Error> {
        let telemetry = workloadTelemetry
        let store = modelStore
        return Task {
            try await telemetry.measure(ResourceWorkloadDescriptor(
                workloadClass: workloadClass,
                kind: .qualityTranscription,
                operation: .prepare)
            ) {
                try await WhisperEngine.prepare(
                    store: store,
                    descriptor: descriptor
                ) { update in
                    let percent = min(100, max(0, Int(update.fraction * 100)))
                    Task { @MainActor [weak self] in
                        self?.reportWhisperProgress(
                            descriptorID: descriptor.id,
                            size: size,
                            percent: percent,
                            isDownloading: update.isDownloading)
                    }
                }
            }
        }
    }

    private func finishWhisperPreparation(
        _ preparation: WhisperPreparation
    ) async throws -> WhisperEngine.PreparedModel {
        do {
            let prepared = try await preparation.task.value
            if whisperPreparation?.generation == preparation.generation {
                whisperPreparation = nil
                whisperPreparedModel = prepared
                whisperPreparationState = .ready(variantID: preparation.descriptorID)
            }
            return prepared
        } catch {
            if whisperPreparation?.generation == preparation.generation {
                whisperPreparation = nil
                whisperPreparationState = error is CancellationError
                    ? .idle
                    : .failed(
                        variantID: preparation.descriptorID,
                        message: error.localizedDescription)
            }
            throw error
        }
    }

    private func reportWhisperProgress(
        descriptorID: String,
        size: String,
        percent: Int,
        isDownloading: Bool
    ) {
        guard whisperPreparation?.descriptorID == descriptorID else { return }
        whisperPreparationState = .preparing(
            variantID: descriptorID,
            size: size,
            percent: percent,
            isDownloading: isDownloading)
        for observer in whisperProgressObservers.values {
            observer(size, percent, isDownloading)
        }
    }

    private static func whisperDescriptor(_ id: String) -> ModelDescriptor? {
        switch id {
        case ModelCatalog.whisperLargeV3Turbo.id:
            ModelCatalog.whisperLargeV3Turbo
        case ModelCatalog.whisperLargeV3_626MB.id:
            ModelCatalog.whisperLargeV3_626MB
        default:
            nil
        }
    }

    private static func whisperSizeLabel(_ descriptor: ModelDescriptor) -> String {
        descriptor.id == ModelCatalog.whisperLargeV3_626MB.id ? "626 MB" : "1.6 GB"
    }

    private static func whisperVariant(
        _ descriptor: ModelDescriptor,
        compact: Bool,
        downloaded: Bool
    ) -> WhisperVariant {
        return WhisperVariant(
            id: descriptor.id,
            compact: compact,
            downloaded: downloaded,
            bytes: Int64(descriptor.totalSizeBytes))
    }
}

private enum WhisperRuntimeError: Error {
    case inconsistentResidency
    case variantInUse
}
