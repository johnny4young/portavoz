import ApplicationKit
import Foundation
import TranscriptionKit

// Vocabulary mining — kept outside the composition root so its type body
// stays below the lint budget.
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
}
