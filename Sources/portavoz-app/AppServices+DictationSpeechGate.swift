import Foundation
import ModelStoreKit
import TranscriptionKit

enum DictationSpeechGateModelState: Equatable {
    case unknown
    case missing
    case downloading(Int)
    case ready
    case failed
}

extension DictationSpeechGate {
    /// Opt-in: off until the user enables it in Settings.
    static let defaultsKey = "dictationSpeechGate"
    /// Silero's reference threshold, below FluidAudio's 0.85 segmentation default:
    /// withholding quiet real speech costs more than letting noise through.
    static let speechProbabilityThreshold: Float = 0.5

    static func heardSpeech(_ batch: VoiceActivityBatch) -> Bool {
        batch.observations.contains { $0.isSpeechActive || $0.speechProbability >= speechProbabilityThreshold }
    }

    /// Silero over the verified installation only; a missing model makes the
    /// verdict undetermined (paste as before), never a download.
    static func silero(store: ModelStore) -> DictationSpeechGate {
        DictationSpeechGate {
            let detector = try await SileroVoiceActivityDetector.load(from: store, channel: .microphone)
            return { chunk in heardSpeech(try await detector.process(chunk)) }
        }
    }
}

extension AppServices {
    func refreshSpeechGateModel() async {
        if case .downloading = speechGateModel { return }
        let installed = await modelLifecycle.installation(for: ModelCatalog.sileroVAD) != nil
        // An install that started during the check owns the state.
        guard !Task.isCancelled else { return }
        if case .downloading = speechGateModel { return }
        speechGateModel = installed ? .ready : .missing
    }

    /// Explicit consent from the Settings toggle or Retry; a pinned ~1 MB download.
    func installSpeechGateModel() async {
        // The disposable composition never reaches the network.
        guard !usesTemporaryMeetingStore else {
            speechGateModel = .missing
            return
        }
        if case .downloading = speechGateModel { return }
        if case .ready = speechGateModel { return }
        speechGateModel = .downloading(0)
        do {
            _ = try await modelLifecycle.install(ModelCatalog.sileroVAD) { [weak self] update in
                guard update.totalBytes > 0 else { return }
                let percent = Int(update.fraction * 100)
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = speechGateModel else { return }
                    speechGateModel = .downloading(percent)
                }
            }
            speechGateModel = .ready
        } catch {
            speechGateModel = .failed
        }
    }
}
