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
        let appleIntelligence: Bool
        if #available(macOS 26.0, *) {
            appleIntelligence = FoundationModelSummaryProvider.unavailabilityReason() == nil
        } else {
            appleIntelligence = false
        }
        let ollama = await OllamaService.isRunning()
        let free =
            (try? URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage)
        return HardwareProfile(
            memoryGB: memoryGB,
            appleIntelligence: appleIntelligence,
            ollamaAvailable: ollama,
            freeDiskGB: Int((free ?? 0) / 1_000_000_000))
    }

}
