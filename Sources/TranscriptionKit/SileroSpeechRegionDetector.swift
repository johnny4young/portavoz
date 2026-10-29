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

    private init(manager: VadManager) {
        self.manager = manager
    }

    public static func load(from store: ModelStore) async throws -> SileroSpeechRegionDetector {
        guard let installed = await store.verifiedInstallation(ModelCatalog.sileroVAD) else {
            throw VoiceActivityDetectionError.modelNotInstalled
        }
        let url = installed.directory.appendingPathComponent(
            ModelCatalog.sileroVADBundleDirectory, isDirectory: true)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try await MLModel.load(contentsOf: url, configuration: configuration)
        return SileroSpeechRegionDetector(manager: VadManager(
            config: VadConfig(defaultThreshold: threshold, computeUnits: .cpuOnly),
            vadModel: model))
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
