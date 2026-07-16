import ApplicationKit
import Foundation
import IntelligenceKit
import PortavozCore
import TranscriptionKit

// Vocabulary mining + hardware advice — self-contained helpers split out
// of the composition root to keep its type body under the lint budget.
extension AppServices {
    /// Mines domain terms from recent transcripts to suggest for the custom
    /// vocabulary (Settings). Bounded: the last 12 meetings' segments.
    /// Dismissed suggestions ("don't suggest again") count as known — a
    /// misheard form the user already corrected must never come back.
    func mineVocabularySuggestions() async -> [String] {
        let existing =
            VocabularyPrompt.parse(
                UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
            + VocabularyPrompt.parse(
                UserDefaults.standard.string(forKey: "vocabularyRejectedSuggestions") ?? "")
        let recent = ((try? await store.meetings()) ?? []).prefix(12)
        var texts: [String] = []
        for meeting in recent {
            guard let detail = try? await store.detail(meeting.id) else { continue }
            texts.append(contentsOf: detail.segments.map(\.text))
        }
        return VocabularyMiner.suggest(from: texts, existing: existing)
    }

    /// The machine's facts for "Recomendado para tu Mac" (M12).
    func currentHardwareProfile() async -> HardwareProfile {
        let memoryGB = Int((ProcessInfo.processInfo.physicalMemory + 500_000_000) / 1_000_000_000)
        let ollama = await OllamaService.isRunning()
        let free =
            (try? URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage)
        return HardwareProfile(
            memoryGB: memoryGB,
            appleIntelligence: foundationModelsCapability.isAvailable,
            ollamaAvailable: ollama,
            freeDiskGB: Int((free ?? 0) / 1_000_000_000))
    }

    /// Chooses a first summary engine exactly once. Existing preferences are
    /// never migrated silently; they receive capability guidance in Settings.
    /// A clean install uses Apple FM when available. Without it, the policy
    /// prefers an installed Ollama chat model, then the explicit-download MLX
    /// fallback.
    func configureInitialSummaryEngineIfNeeded() async {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "summaryEngine") == nil else { return }

        let profile = await currentHardwareProfile()
        let models = profile.ollamaAvailable
            ? await OllamaService.models().map(\.name)
            : []
        guard defaults.object(forKey: "summaryEngine") == nil,
            let configuration = InitialSummaryEnginePolicy.choose(
                profile: profile,
                ollamaModels: models)
        else { return }

        if let model = configuration.ollamaModel {
            defaults.set(model, forKey: "ollamaModel")
        }
        defaults.set(configuration.engine.rawValue, forKey: "summaryEngine")
    }

}

struct InitialSummaryEngineConfiguration: Equatable {
    let engine: SummaryEngine
    let ollamaModel: String?
}

enum InitialSummaryEnginePolicy {
    static func choose(
        profile: HardwareProfile,
        ollamaModels: [String]
    ) -> InitialSummaryEngineConfiguration? {
        switch HardwareRecommender.advise(profile).engine {
        case .apple:
            return InitialSummaryEngineConfiguration(
                engine: .appleOnDevice,
                ollamaModel: nil)
        case .ollama:
            if let model = ollamaModels.first(where: isChatModel) {
                return InitialSummaryEngineConfiguration(
                    engine: .ollama,
                    ollamaModel: model)
            }
            var withoutOllama = profile
            withoutOllama.ollamaAvailable = false
            return choose(profile: withoutOllama, ollamaModels: [])
        case .mlx:
            return InitialSummaryEngineConfiguration(engine: .mlx, ollamaModel: nil)
        case .none:
            return nil
        }
    }

    static func isChatModel(_ name: String) -> Bool {
        !name.localizedCaseInsensitiveContains("ocr")
    }
}
