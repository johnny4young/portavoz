import Foundation
import ModelStoreKit
import TranscriptionKit

extension AppServices {
    /// Speech detector for Whisper batch passes. Refine and import already
    /// download Whisper on demand; the ~1 MB detector rides the same consent.
    /// Nil keeps the whole-file path.
    func batchSpeechDetector() async -> SileroSpeechRegionDetector? {
        if !usesTemporaryMeetingStore,
            await modelLifecycle.installation(for: ModelCatalog.sileroVAD) == nil {
            _ = try? await modelLifecycle.install(ModelCatalog.sileroVAD) { _ in }
        }
        return try? await SileroSpeechRegionDetector.load(from: modelStore)
    }
}
