import Foundation
import ModelStoreKit
import PortavozCore

/// Opt-in warm load for dictation. It never pins weights: the lease ends at
/// once, so idle and pressure release still apply.
enum DictationPrewarmPolicy {
    static let defaultsKey = "dictationPrewarm"

    struct Conditions: Equatable {
        var dictationEnabled: Bool
        var prewarmEnabled: Bool
        var profile: AppModelMemoryPreferences.Profile
        var engine: LiveSpeechSelection
        var underPressure: Bool
        var lowPowerMode: Bool
        var temporaryStore: Bool
    }

    static func shouldWarm(_ conditions: Conditions) -> Bool {
        conditions.dictationEnabled && conditions.prewarmEnabled
            && conditions.profile == .balanced && conditions.engine == .parakeet
            && !conditions.underPressure && !conditions.lowPowerMode
            && !conditions.temporaryStore
    }
}

extension AppServices {
    var dictationPrewarmConditions: DictationPrewarmPolicy.Conditions {
        DictationPrewarmPolicy.Conditions(
            dictationEnabled: defaults.bool(forKey: DictationController.defaultsKey),
            prewarmEnabled: defaults.bool(forKey: DictationPrewarmPolicy.defaultsKey),
            profile: modelMemoryPreferences.profile,
            engine: LiveSpeechPurpose.dictation.selectedEngine(in: defaults),
            underPressure: resourcePressureMonitor?.current.requestsIdleModelRelease ?? false,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            temporaryStore: usesTemporaryMeetingStore)
    }

    /// Loads only an installed, verified model; a pre-warm never downloads.
    func prewarmDictationIfConfigured() {
        guard DictationPrewarmPolicy.shouldWarm(dictationPrewarmConditions),
              let descriptor = ModelCatalog.recommended(for: .liveTranscription)
        else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  await modelLifecycle.installation(for: descriptor) != nil,
                  DictationPrewarmPolicy.shouldWarm(dictationPrewarmConditions)
            else { return }
            do {
                try await admitModelRuntimeLoad(.liveSpeech)
                try await acquireLiveTranscriptionRuntime(for: .dictation).finish()
            } catch {
                return
            }
        }
    }
}
