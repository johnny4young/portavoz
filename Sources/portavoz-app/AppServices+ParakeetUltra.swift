import Foundation
import ModelStoreKit
import TranscriptionKit

extension AppServices {
    /// Ultra only when it is selected and already verified; otherwise v3.
    func dictationCheckpoint() async -> ParakeetCheckpoint {
        guard LiveSpeechPurpose.dictation.selectedEngine(in: defaults) == .parakeetUltra,
              await modelLifecycle.installation(for: ModelCatalog.parakeetUltra) != nil
        else { return .v3 }
        return .ultra
    }

    func refreshParakeetUltraModel() async {
        if case .downloading = parakeetUltraModel { return }
        let installed = await modelLifecycle.installation(for: ModelCatalog.parakeetUltra) != nil
        guard !Task.isCancelled else { return }
        if case .downloading = parakeetUltraModel { return }
        parakeetUltraModel = installed ? .ready : .missing
    }

    /// Choosing Ultra in Settings is the consent for its pinned ~613 MB download.
    func installParakeetUltraModel() async {
        // The disposable composition never reaches the network.
        guard !usesTemporaryMeetingStore else {
            parakeetUltraModel = .missing
            return
        }
        if case .downloading = parakeetUltraModel { return }
        if case .ready = parakeetUltraModel { return }
        parakeetUltraModel = .downloading(0)
        do {
            _ = try await modelLifecycle.install(ModelCatalog.parakeetUltra) { [weak self] update in
                guard update.totalBytes > 0 else { return }
                let percent = Int(update.fraction * 100)
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = parakeetUltraModel else { return }
                    parakeetUltraModel = .downloading(percent)
                }
            }
            parakeetUltraModel = .ready
        } catch {
            parakeetUltraModel = .failed
        }
    }
}
