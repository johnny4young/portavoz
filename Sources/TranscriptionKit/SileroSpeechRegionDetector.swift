import CoreML
import FluidAudio
import Foundation
import ModelStoreKit

/// Whole-file Silero speech segmentation for batch transcription. Loads only
/// ModelStore's verified installation; it never downloads.
public actor SileroSpeechRegionDetector: SpeechRegionDetecting {
    /// Silero's reference threshold: missing quiet speech costs more than
    /// decoding a little noise.
    static let threshold: Float = 0.5

    private let manager: VadManager
    private let installationLease: ModelStore.ModelLease?

    private init(
        manager: VadManager,
        installationLease: ModelStore.ModelLease?
    ) {
        self.manager = manager
        self.installationLease = installationLease
    }

    public static func load(from store: ModelStore) async throws -> SileroSpeechRegionDetector {
        guard await store.verifiedInstallation(ModelCatalog.sileroVAD) != nil else {
            throw VoiceActivityDetectionError.modelNotInstalled
        }
        let lease: ModelStore.ModelLease
        do {
            lease = try await store.lease(ModelCatalog.sileroVAD)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VoiceActivityDetectionError.modelNotInstalled
        }
        let url = lease.directory.appendingPathComponent(
            ModelCatalog.sileroVADBundleDirectory, isDirectory: true)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try await MLModel.load(contentsOf: url, configuration: configuration)
        return SileroSpeechRegionDetector(
            manager: VadManager(
                config: VadConfig(defaultThreshold: threshold, computeUnits: .cpuOnly),
                vadModel: model),
            installationLease: lease)
    }

    public func speechRegions(in samples: [Float]) async throws -> [ClosedRange<TimeInterval>] {
        let segments = try await manager.segmentSpeech(
            samples,
            config: VadSegmentationConfig(
                minSpeechDuration: 0.25,
                minSilenceDuration: 0.5,
                maxSpeechDuration: SpeechDecodeWindows.maximumWindow,
                speechPadding: 0.1))
        return segments.map { $0.startTime...$0.endTime }
    }
}
