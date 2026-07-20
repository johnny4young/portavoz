import Foundation

/// One user-confirmed human identity shared across meeting observations.
public struct Person: Codable, Sendable, Identifiable {
    public var id: PersonID
    public var preferredName: String

    public init(id: PersonID = PersonID(), preferredName: String) {
        self.id = id
        self.preferredName = preferredName
    }
}

/// Evidence that supplied a meeting-local name before the user explicitly
/// confirmed its canonical-person link. This records provenance; it never
/// grants permission to link by itself.
public enum PersonAliasSource: String, Codable, CaseIterable, Sendable {
    case manualName = "manual-name"
    case transcriptSuggestion = "transcript-suggestion"
    case calendarSuggestion = "calendar-suggestion"
    case voiceSuggestion = "voice-suggestion"
}

/// A normalized lookup alias owned by one canonical person. The same alias
/// may belong to several people so ambiguity remains representable.
public struct PersonAlias: Codable, Sendable, Identifiable {
    public let id: UUID
    public let personID: PersonID
    public let normalizedAlias: String
    public let source: PersonAliasSource
    public let confidence: Double

    public init(
        id: UUID = UUID(),
        personID: PersonID,
        normalizedAlias: String,
        source: PersonAliasSource,
        confidence: Double
    ) {
        self.id = id
        self.personID = personID
        self.normalizedAlias = normalizedAlias
        self.source = source
        self.confidence = confidence
    }
}

/// The atomic result of one user-confirmed observed-speaker link.
public struct ConfirmedPersonLink: Sendable {
    public let person: Person
    public let speaker: Speaker

    public init(person: Person, speaker: Speaker) {
        self.person = person
        self.speaker = speaker
    }
}

/// Stable alias normalization for candidate lookup only. A match is evidence
/// for a confirmation dialog, never authority to merge people.
public enum PersonAliasNormalizer {
    private static let locale = Locale(identifier: "en_US_POSIX")

    public static func displayName(_ value: String) -> String? {
        let collapsed = value.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    public static func normalize(_ value: String) -> String? {
        guard let displayName = displayName(value) else { return nil }
        return displayName
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: locale)
            .lowercased(with: locale)
    }
}

/// Deterministic lexical admission for a proposed human name. Matching uses
/// complete Unicode letter/number tokens rather than substring containment, so
/// a short name such as "Ana" cannot be admitted from an unrelated word such
/// as "analysis". This proves only that a source contains the proposed name;
/// it never proves that the source belongs to a particular speaker.
public enum PersonNameEvidenceMatcher {
    public static func contains(_ proposedName: String, in source: String) -> Bool {
        let proposedTokens = tokens(in: proposedName)
        let sourceTokens = tokens(in: source)
        guard proposedTokens.reduce(0, { $0 + $1.count }) > 1,
              sourceTokens.count >= proposedTokens.count
        else {
            return false
        }

        return (0...(sourceTokens.count - proposedTokens.count)).contains { start in
            Array(sourceTokens[start..<(start + proposedTokens.count)]) == proposedTokens
        }
    }

    private static func tokens(in value: String) -> [String] {
        guard let normalized = PersonAliasNormalizer.normalize(value) else { return [] }
        return normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
