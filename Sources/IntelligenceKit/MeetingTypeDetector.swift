import Foundation
import PortavozCore

#if canImport(FoundationModels)
import FoundationModels

/// Classifies a finished meeting into a typed `Recipe` (M13b): powers the
/// "Summarize as Standup?" chip in the detail view. Suggestion-only — the
/// user clicks to regenerate; nothing restructures on its own. The gate is
/// deterministic: only known non-general recipe ids survive, everything
/// else (including model doubt) collapses to nil.
@available(macOS 26.0, *)
public enum MeetingTypeDetector {
    /// Pure so tests pin the shape. Few-shot on purpose: the 3B ignores
    /// abstract rules without literal examples (Companion finding).
    static let instructions = """
        You classify a meeting transcript excerpt into exactly one type.
        Types: standup (each person reports progress, blockers and plans), \
        one-on-one (two people, personal check-in, feedback, career or work agreements), \
        planning (scoping goals, risks and next steps for future work), \
        interview (one side evaluates the other's background and skills), \
        general (anything else: reviews, debugging sessions, broad discussions).
        Examples:
        - "yesterday I finished the migration, today I'll take the API, no blockers" → standup
        - "how are you feeling about the workload? — honestly a bit stretched" → one-on-one
        - "for Q3 the goal is the iOS launch; main risk is the review times" → planning
        - "tell me about your experience with distributed systems" → interview
        - "the bug is in the retry loop, look at line 40" → general
        When unsure, answer general.
        """

    /// The excerpt the classifier sees: speaker count (a 1:1 needs exactly
    /// two people) plus the first substantial lines, capped so the prompt
    /// never balloons on long meetings.
    static func excerpt(segments: [TranscriptSegment], speakerCount: Int) -> String {
        var lines = ["Speakers: \(speakerCount)"]
        var total = 0
        for segment in segments where segment.text.count >= 15 {
            lines.append(segment.text)
            total += segment.text.count
            if total > 1600 { break }
        }
        return lines.joined(separator: "\n")
    }

    /// nil = general or unsure. Background priority: this runs opportunistically
    /// when a detail view opens and must never delay interactive work (D29).
    public static func detect(
        segments: [TranscriptSegment], speakerCount: Int
    ) async -> Recipe? {
        guard segments.count >= 4 else { return nil }
        let prompt = excerpt(segments: segments, speakerCount: speakerCount)
        let session = LanguageModelSession(instructions: instructions)
        let detected: DetectedMeetingType? = try? await IntelligenceScheduler.shared
            .run(.background) {
                try await session.respond(
                    to: prompt,
                    generating: DetectedMeetingType.self,
                    options: GenerationOptions(sampling: .greedy)
                ).content
            }
        guard let detected else { return nil }
        let id = detected.type.lowercased().trimmingCharacters(in: .whitespaces)
        guard id != Recipe.general.id, let recipe = Recipe.byID(id) else { return nil }
        return recipe
    }
}

@available(macOS 26.0, *)
@Generable(description: "Meeting type classification")
struct DetectedMeetingType {
    @Guide(description: "Exactly one of: standup, one-on-one, planning, interview, general")
    var type: String
}
#endif
