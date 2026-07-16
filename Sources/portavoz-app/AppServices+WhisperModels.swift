import Foundation
import ModelStoreKit
import TranscriptionKit

extension AppServices {
    enum WhisperDownloadState: Equatable {
        case idle
        case downloading(variantID: String, size: String, percent: Int)
        case ready(variantID: String)
        case failed(variantID: String, message: String)

        var isDownloading: Bool {
            if case .downloading = self { return true }
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

    typealias WhisperProgressObserver = @MainActor @Sendable (String, Int) -> Void

    /// The D7 quality re-pass engine. Refine and Import join the same verified
    /// preparation that Settings can start explicitly in the background.
    func loadWhisperIfNeeded(
        descriptor requestedDescriptor: ModelDescriptor? = nil,
        progress: @escaping @MainActor (String) -> Void,
        downloadProgress: WhisperProgressObserver? = nil
    ) async throws -> WhisperEngine {
        let descriptor = requestedDescriptor ?? Self.preferredWhisperDescriptor()
        whisperIdleGeneration += 1
        if let whisper, whisperVariantID == descriptor.id { return whisper }

        let prepared = try await preparedWhisperModel(
            descriptor,
            observer: downloadProgress)
        progress(L10n.text("Loading Whisper…"))
        let engine = try await WhisperEngine.loadPrepared(prepared)
        whisper = engine
        whisperVariantID = descriptor.id
        return engine
    }

    /// Starts an app-scoped verified download. Closing Settings or navigating
    /// away does not cancel it; a later Refine joins the exact same task.
    func prepareWhisperVariant(_ id: String) {
        guard let descriptor = Self.whisperDescriptor(id),
              !whisperDownloadState.isDownloading
        else { return }
        whisperBackgroundPreparation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.whisperBackgroundPreparation = nil }
            _ = try? await self.preparedWhisperModel(descriptor, observer: nil)
        }
    }

    static func preferredWhisperDescriptor() -> ModelDescriptor {
        UserDefaults.standard.bool(forKey: "whisperCompact")
            ? ModelCatalog.whisperLargeV3_626MB
            : ModelCatalog.whisperLargeV3Turbo
    }

    func whisperVariants() -> [WhisperVariant] {
        let forcedMissing = ProcessInfo.processInfo.arguments.contains("-use-temp-store")
        let tokenizerReady = !forcedMissing
            && Self.modelArtifactsAreComplete(ModelCatalog.whisperTokenizer)
        return [
            Self.whisperVariant(
                ModelCatalog.whisperLargeV3Turbo,
                compact: false,
                tokenizerReady: tokenizerReady,
                forcedMissing: forcedMissing),
            Self.whisperVariant(
                ModelCatalog.whisperLargeV3_626MB,
                compact: true,
                tokenizerReady: tokenizerReady,
                forcedMissing: forcedMissing)
        ]
    }

    func deleteWhisperVariant(_ id: String) {
        guard let descriptor = Self.whisperDescriptor(id) else { return }
        if case .downloading(let activeID, _, _) = whisperDownloadState,
            activeID == id { return }
        try? FileManager.default.removeItem(at: Self.modelDir(descriptor))
        if whisperVariantID == id {
            whisper = nil
            whisperVariantID = nil
        }
        if whisperPreparedModel?.descriptorID == id {
            whisperPreparedModel = nil
        }
        switch whisperDownloadState {
        case .ready(let variantID) where variantID == id:
            whisperDownloadState = .idle
        case .failed(let variantID, _) where variantID == id:
            whisperDownloadState = .idle
        default:
            break
        }
    }

    /// Drops the loaded runtime but never removes the verified files.
    func releaseWhisper() {
        whisper = nil
        whisperVariantID = nil
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
}

extension AppServices {
    private func preparedWhisperModel(
        _ descriptor: ModelDescriptor,
        observer: WhisperProgressObserver?
    ) async throws -> WhisperEngine.PreparedModel {
        if let whisperPreparedModel,
            whisperPreparedModel.descriptorID == descriptor.id {
            return whisperPreparedModel
        }
        let observerID = observer.map { observer in
            let id = UUID()
            whisperProgressObservers[id] = observer
            if case .downloading(let variantID, let size, let percent) = whisperDownloadState,
                variantID == descriptor.id {
                observer(size, percent)
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
        whisperDownloadState = .downloading(
            variantID: descriptor.id,
            size: size,
            percent: 0)
        let task = Task {
            try await WhisperEngine.prepare(
                store: ModelStore(),
                descriptor: descriptor
            ) { update in
                let percent = min(100, max(0, Int(update.fraction * 100)))
                Task { @MainActor [weak self] in
                    self?.reportWhisperProgress(
                        descriptorID: descriptor.id,
                        size: size,
                        percent: percent)
                }
            }
        }
        let preparation = WhisperPreparation(
            generation: generation,
            descriptorID: descriptor.id,
            task: task)
        whisperPreparation = preparation
        return try await finishWhisperPreparation(preparation)
    }

    private func finishWhisperPreparation(
        _ preparation: WhisperPreparation
    ) async throws -> WhisperEngine.PreparedModel {
        do {
            let prepared = try await preparation.task.value
            if whisperPreparation?.generation == preparation.generation {
                whisperPreparation = nil
                whisperPreparedModel = prepared
                whisperDownloadState = .ready(variantID: preparation.descriptorID)
            }
            return prepared
        } catch {
            if whisperPreparation?.generation == preparation.generation {
                whisperPreparation = nil
                whisperDownloadState = error is CancellationError
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
        percent: Int
    ) {
        guard whisperPreparation?.descriptorID == descriptorID else { return }
        whisperDownloadState = .downloading(
            variantID: descriptorID,
            size: size,
            percent: percent)
        for observer in whisperProgressObservers.values {
            observer(size, percent)
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
        tokenizerReady: Bool,
        forcedMissing: Bool
    ) -> WhisperVariant {
        let downloaded = !forcedMissing && tokenizerReady
            && modelArtifactsAreComplete(descriptor)
        let directory = modelDir(descriptor)
        return WhisperVariant(
            id: descriptor.id,
            compact: compact,
            downloaded: downloaded,
            bytes: downloaded
                ? directorySize(directory)
                : Int64(descriptor.totalSizeBytes))
    }

    private static func modelArtifactsAreComplete(_ descriptor: ModelDescriptor) -> Bool {
        let directory = modelDir(descriptor)
        return descriptor.artifacts.allSatisfy { artifact in
            let file = directory.appendingPathComponent(artifact.path)
            guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: file.path),
                let size = attributes[.size] as? NSNumber
            else { return false }
            return size.intValue == artifact.sizeBytes
        }
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64(
                (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
