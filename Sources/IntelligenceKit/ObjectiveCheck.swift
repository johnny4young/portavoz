import Foundation
import PortavozCore

/// Pure gating for the periodic objective check-off pass: which
/// closed rows the detector may look at, and whether a pass is worth a
/// model call at all. Mirrors `CatchUpPolicy`'s shape so the live surface
/// keeps one idiom for windowed work.
public enum ObjectiveCheckPolicy {
    /// A tighter window than catch-up: coverage evidence should be RECENT —
    /// the pass runs every rolling tick, so anything older was already seen.
    public static let window: TimeInterval = 150
    public static let minimumRows = 2

    /// Closed rows inside the window; the still-growing newest row is
    /// excluded exactly like every other live consumer.
    public static func clip(_ captions: [TranscriptSegment]) -> [TranscriptSegment] {
        let closed = captions.dropLast()
        guard let newest = closed.last else { return [] }
        let cutoff = newest.endTime - window
        return closed.filter { $0.endTime >= cutoff }
    }

    /// A pass runs only when it can change something: pending objectives
    /// exist and the window carries enough conversation to judge.
    public static func shouldRun(
        pendingObjectives: Int,
        clippedRows: Int
    ) -> Bool {
        pendingObjectives > 0 && clippedRows >= minimumRows
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// The model half of live check-off: given the user's pending objectives
/// and a recent conversation window, name which objectives were ACTUALLY
/// addressed. Deterministic gate on the way out — indexes outside the
/// pending list are dropped, so model drift can never check an objective
/// that was not offered.
@available(macOS 26.0, *)
public enum ObjectiveCheckDetector {
    /// Few-shot on purpose, like the meeting-type detector: the 3B needs
    /// literal examples, and the bar is deliberately high — mentioning a
    /// topic is not covering it.
    static let instructions = """
        You check which meeting objectives were genuinely addressed in a \
        conversation excerpt. An objective counts as addressed only when the \
        excerpt shows the topic being discussed with substance — a decision, \
        an answer, a concrete exchange — not merely mentioned or announced.
        Examples:
        - objective "agree on the launch date", excerpt "so we're going with \
        March 12, everyone good? — yes" → addressed
        - objective "review the budget", excerpt "we still need to go over \
        the budget later" → NOT addressed (announced, not reviewed)
        - objective "discuss hiring", excerpt about an unrelated bug → NOT \
        addressed
        \(PromptFactory.sourceMaterialGuard())
        Answer with the numbers of addressed objectives only; when in doubt, \
        leave an objective unaddressed.
        """

    /// Prompt body: numbered pending objectives + the recent window.
    static func prompt(
        objectives: [String],
        window: [TranscriptSegment]
    ) -> String {
        let numbered = objectives.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let excerpt = window
            .map { TranscriptFormatter.escapeEvidenceTags(in: $0.text) }
            .joined(separator: "\n")
        return "Objectives:\n\(numbered)\n\nConversation excerpt:\n\(excerpt)"
    }

    /// Returns 0-based indexes into `objectives` that the excerpt shows as
    /// addressed. Empty on doubt, failure, or an unavailable model — the
    /// caller keeps its pending list untouched.
    public static func addressedIndexes(
        objectives: [String],
        window: [TranscriptSegment]
    ) async -> [Int] {
        guard !objectives.isEmpty, !window.isEmpty else { return [] }
        let session = LanguageModelSession(instructions: instructions)
        let prompt = prompt(objectives: objectives, window: window)
        let detected: DetectedObjectiveCoverage? = try? await IntelligenceScheduler
            .shared.run(.background) {
                try await session.respond(
                    to: prompt,
                    generating: DetectedObjectiveCoverage.self,
                    options: GenerationOptions(sampling: .greedy)
                ).content
            }
        guard let detected else { return [] }
        return detected.addressed
            .map { $0 - 1 }
            .filter { objectives.indices.contains($0) }
    }
}

@available(macOS 26.0, *)
@Generable(description: "Which objectives the excerpt shows as addressed")
struct DetectedObjectiveCoverage {
    @Guide(description: "1-based numbers of objectives genuinely addressed; empty when none")
    var addressed: [Int]
}
#endif
