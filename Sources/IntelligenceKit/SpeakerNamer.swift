import Foundation
import PortavozCore

/// An untrusted label → real-name proposal from the concrete generator.
/// The application boundary independently derives trusted transcript or
/// calendar evidence before presenting it, and nothing applies itself.
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

/// Defense-in-depth filtering for the concrete generator. The application
/// workflow repeats admission independently and replaces model-authored prose
/// with typed evidence from the real transcript or calendar candidate set.
public enum NameSuggestionFilter {
    public static func validSuggestions(
        _ suggestions: [NameSuggestion],
        transcript: String,
        unnamedLabels: Set<String>,
        attendeeCandidates: [String] = []
    ) -> [NameSuggestion] {
        var admittedLabels: Set<String> = []
        return suggestions.compactMap { suggestion in
            let label = suggestion.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name = PersonAliasNormalizer.displayName(suggestion.name),
                  unnamedLabels.contains(label),
                  !admittedLabels.contains(label),
                  PersonNameEvidenceMatcher.contains(name, in: transcript)
                    || attendeeCandidates.contains(where: {
                        PersonNameEvidenceMatcher.contains(name, in: $0)
                    })
            else {
                return nil
            }
            admittedLabels.insert(label)
            return NameSuggestion(
                label: label,
                name: name,
                evidence: suggestion.evidence.trimmingCharacters(in: .whitespacesAndNewlines))
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

    /// `attendeeCandidates` (M6/EventKit): names from calendar events around
    /// the meeting. They widen the candidate set but remain suggestions, not
    /// identity proof; the user still confirms every accepted result.
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

        // The 4096-token window also holds instructions, schema and output;
        // if a dense excerpt still overflows, halve it and try once more
        // before giving up.
        let suggestions: [NameSuggestion]
        do {
            suggestions = try await propose(excerpt: excerpt, attendees: attendeeCandidates)
        } catch {
            suggestions = try await propose(
                excerpt: String(excerpt.prefix(excerpt.count / 2)),
                attendees: attendeeCandidates)
        }

        return NameSuggestionFilter.validSuggestions(
            suggestions,
            transcript: transcript,
            unnamedLabels: unnamed,
            attendeeCandidates: attendeeCandidates)
    }

    private func propose(
        excerpt: String, attendees: [String]
    ) async throws -> [NameSuggestion] {
        var prompt = "Transcript:\n\n\(excerpt)\n\n"
        if !attendees.isEmpty {
            prompt +=
                "Calendar attendees (possible names, not identity proof): "
                + attendees.prefix(12).joined(separator: ", ") + "\n\n"
        }
        prompt += "Suggest only labels supported by the transcript or calendar candidates."
        let finalPrompt = prompt

        let session = LanguageModelSession(instructions: PromptFactory.namingInstructions())
        // Mapped INSIDE the slot: Response<T> isn't Sendable.
        return try await IntelligenceScheduler.shared.run(.interactive) {
            let response = try await session.respond(
                to: finalPrompt,
                generating: GeneratedNameSuggestions.self,
                options: GenerationOptions(sampling: .greedy))
            return response.content.suggestions.map {
                NameSuggestion(label: $0.label, name: $0.name, evidence: $0.evidence)
            }
        }
    }
}

@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "Speaker label to possible real-name mappings for user review")
struct GeneratedNameSuggestions {
    @Guide(
        description:
            "One entry per label supported by transcript wording "
                + "or a supplied calendar candidate. "
                + "Empty array when unsupported"
    )
    var suggestions: [GeneratedNameSuggestion]
}

@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "One proposed label→name mapping")
struct GeneratedNameSuggestion {
    @Guide(description: "The speaker label exactly as it appears, e.g. S1")
    var label: String
    @Guide(description: "The possible real name from the transcript or calendar candidates")
    var name: String
    @Guide(description: "The exact transcript quote or calendar candidate that supports it")
    var evidence: String
}
#endif
