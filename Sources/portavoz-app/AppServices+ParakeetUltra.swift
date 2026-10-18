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
        // Disposable UI tests can hold a download in flight without any network.
        if usesTemporaryMeetingStore, ProcessInfo.processInfo.arguments.contains("-seed-parakeet-ultra-downloading") {
            parakeetUltraModel = .downloading(42)
            parakeetUltraDownload = Task { try? await Task.sleep(for: .seconds(3_600)) }
            return
        }
        let installed = await modelLifecycle.installation(for: ModelCatalog.parakeetUltra) != nil
        guard !Task.isCancelled else { return }
        if case .downloading = parakeetUltraModel { return }
        parakeetUltraModel = installed ? .ready : .missing
    }

    /// Starts the consented download once; Settings can cancel it.
    func startParakeetUltraDownload() {
        guard parakeetUltraDownload == nil else { return }
        parakeetUltraDownload = Task { [weak self] in
            await self?.installParakeetUltraModel()
            self?.parakeetUltraDownload = nil
        }
    }

    /// Stops a download in progress; verified files already on disk stay.
    func cancelParakeetUltraDownload() {
        parakeetUltraDownload?.cancel()
        parakeetUltraDownload = nil
        if case .downloading = parakeetUltraModel { parakeetUltraModel = .missing }
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
            parakeetUltraModel = Task.isCancelled ? .missing : .ready
        } catch {
            parakeetUltraModel = Task.isCancelled || error is CancellationError ? .missing : .failed
        }
    }
}
