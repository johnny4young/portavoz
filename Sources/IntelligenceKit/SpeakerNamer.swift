import Foundation
import PortavozCore

/// A proposed label → real-name mapping, always backed by a quote from
/// the transcript. The user accepts with one tap; nothing applies itself.
public struct NameSuggestion: Codable, Sendable, Equatable {
    public let label: String
    public let name: String
    public let evidence: String

    public init(label: String, name: String, evidence: String) {
        self.label = label
        self.name = name
        self.evidence = evidence
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// Proposes real names for diarization labels (S1, S2…) using only what
/// the transcript itself proves: self-introductions and being addressed
/// by name around their turns. On-device (M6, "1-tap speaker→name").
@available(macOS 26.0, iOS 26.0, *)
public struct SpeakerNamer: Sendable {
    public init() {}

    public func suggestNames(
        segments: [TranscriptSegment], speakers: [Speaker]
    ) async throws -> [NameSuggestion] {
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            throw IntelligenceError.modelUnavailable(reason)
        }
        let candidates = Set(
            speakers.filter { !$0.isMe && $0.displayName == nil }.map(\.label))
        guard !candidates.isEmpty else { return [] }

        let transcript = TranscriptFormatter.format(segments: segments, speakers: speakers)
        // Naming only needs the conversational cues, which cluster around
        // greetings/handoffs; one window of transcript is plenty.
        let clipped = String(transcript.prefix(TranscriptFormatter.onDeviceReduceBudget))

        let session = LanguageModelSession(instructions: PromptFactory.namingInstructions())
        let response = try await session.respond(
            to: "Transcript:\n\n\(clipped)\n\nName the speaker labels you can prove.",
            generating: GeneratedNameSuggestions.self,
            options: GenerationOptions(sampling: .greedy))

        // Never trust, verify: the model happily fabricates names with
        // fabricated evidence (observed: "John" out of thin air). A valid
        // suggestion's name must literally appear in the transcript.
        let haystack = transcript.lowercased()
        return response.content.suggestions
            .filter { suggestion in
                candidates.contains(suggestion.label)
                    && suggestion.name.count > 1
                    && haystack.contains(suggestion.name.lowercased())
            }
            .map { NameSuggestion(label: $0.label, name: $0.name, evidence: $0.evidence) }
    }
}

@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "Speaker label to real name mappings proven by the transcript")
struct GeneratedNameSuggestions {
    @Guide(
        description:
            "One entry per label whose real name the transcript PROVES. Empty array when nothing is provable"
    )
    var suggestions: [GeneratedNameSuggestion]
}

@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "One proven label→name mapping")
struct GeneratedNameSuggestion {
    @Guide(description: "The speaker label exactly as it appears, e.g. S1")
    var label: String
    @Guide(description: "The person's real name as stated in the transcript")
    var name: String
    @Guide(description: "The exact transcript quote that proves it")
    var evidence: String
}
#endif
