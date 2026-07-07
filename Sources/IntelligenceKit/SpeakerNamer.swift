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

/// Never-trust-verify for name suggestions, shared by every entry point
/// and unit-testable without a model: a proposed name must literally
/// appear in the transcript OR among the calendar attendee candidates —
/// the model fabricates names with fabricated evidence otherwise
/// (observed: "John" out of thin air).
public enum NameSuggestionFilter {
    public static func validSuggestions(
        _ suggestions: [NameSuggestion],
        transcript: String,
        unnamedLabels: Set<String>,
        attendeeCandidates: [String] = []
    ) -> [NameSuggestion] {
        let haystack = transcript.lowercased()
        let candidates = Set(attendeeCandidates.map { $0.lowercased() })
        return suggestions.filter { suggestion in
            guard unnamedLabels.contains(suggestion.label), suggestion.name.count > 1 else {
                return false
            }
            let name = suggestion.name.lowercased()
            return haystack.contains(name)
                || candidates.contains(name)
                || candidates.contains { $0.hasPrefix(name + " ") || $0.contains(" " + name) }
        }
    }
}

/// Picks the transcript lines that can actually prove a name — each
/// speaker's first substantial utterances (self-introductions cluster
/// there) plus lines that mention an attendee candidate (being addressed)
/// — and formats them as one compact window. The blind 3000-char prefix it
/// replaces both overflowed the 4096-token context (instructions + schema
/// + attendees share it; observed: "Exceeded model context window size")
/// and missed names dropped later in the meeting.
public enum NamingExcerpt {
    public static func build(
        segments: [TranscriptSegment],
        speakers: [Speaker],
        attendeeCandidates: [String] = [],
        perSpeaker: Int = 3,
        minLength: Int = 25,
        budget: Int = 2000
    ) -> String {
        var pickedIDs: Set<UUID> = []
        var chosen: [TranscriptSegment] = []
        var perSpeakerCount: [SpeakerID?: Int] = [:]
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= minLength else { continue }
            guard perSpeakerCount[segment.speakerID, default: 0] < perSpeaker else { continue }
            perSpeakerCount[segment.speakerID, default: 0] += 1
            pickedIDs.insert(segment.id)
            chosen.append(segment)
        }

        if !attendeeCandidates.isEmpty {
            let nameTokens = attendeeCandidates
                .flatMap { $0.split(separator: " ") }
                .map { $0.lowercased() }
                .filter { $0.count > 2 }
            for segment in segments where !pickedIDs.contains(segment.id) {
                let lower = segment.text.lowercased()
                if nameTokens.contains(where: { lower.contains($0) }) {
                    pickedIDs.insert(segment.id)
                    chosen.append(segment)
                }
            }
        }

        chosen.sort { $0.startTime < $1.startTime }
        let formatted = TranscriptFormatter.format(segments: chosen, speakers: speakers)
        return String(formatted.prefix(budget))
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

    /// `attendeeCandidates` (M6/EventKit): names from calendar events
    /// around the meeting. They widen what the verifier accepts and are
    /// offered to the model as hints — evidence is still required.
    public func suggestNames(
        segments: [TranscriptSegment],
        speakers: [Speaker],
        attendeeCandidates: [String] = []
    ) async throws -> [NameSuggestion] {
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            throw IntelligenceError.modelUnavailable(reason)
        }
        let unnamed = Set(
            speakers.filter { !$0.isMe && $0.displayName == nil }.map(\.label))
        guard !unnamed.isEmpty else { return [] }

        let transcript = TranscriptFormatter.format(segments: segments, speakers: speakers)
        let excerpt = NamingExcerpt.build(
            segments: segments, speakers: speakers, attendeeCandidates: attendeeCandidates)

        var prompt = "Transcript:\n\n\(excerpt)\n\n"
        if !attendeeCandidates.isEmpty {
            prompt +=
                "Calendar attendees (candidates — transcript proof is still required): "
                + attendeeCandidates.prefix(12).joined(separator: ", ") + "\n\n"
        }
        prompt += "Name the speaker labels you can prove."

        let session = LanguageModelSession(instructions: PromptFactory.namingInstructions())
        let response = try await session.respond(
            to: prompt,
            generating: GeneratedNameSuggestions.self,
            options: GenerationOptions(sampling: .greedy))

        return NameSuggestionFilter.validSuggestions(
            response.content.suggestions.map {
                NameSuggestion(label: $0.label, name: $0.name, evidence: $0.evidence)
            },
            transcript: transcript,
            unnamedLabels: unnamed,
            attendeeCandidates: attendeeCandidates)
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
