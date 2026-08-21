import Foundation

enum RetrievalChunkResourceFixtureError:
    Error, Equatable, LocalizedError {
    case unreadable
    case tooLarge
    case invalidJSON
    case unsupportedSchema
    case invalidBounds
    case repeatedIdentity
    case invalidSegment
    case inconsistentMeeting
    case unorderedMeeting
    case mixedLanguageTurn
    case missingBilingualCoverage

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "retrieval chunk resource fixture cannot be read"
        case .tooLarge:
            "retrieval chunk resource fixture exceeds 8 MiB"
        case .invalidJSON:
            "retrieval chunk resource fixture is not valid JSON"
        case .unsupportedSchema:
            "retrieval chunk resource fixture schema is unsupported"
        case .invalidBounds:
            "retrieval chunk resource fixture bounds are invalid"
        case .repeatedIdentity:
            "retrieval chunk resource fixture identities repeat"
        case .invalidSegment:
            "retrieval chunk resource fixture contains an invalid segment"
        case .inconsistentMeeting:
            "retrieval chunk resource fixture meeting metadata is inconsistent"
        case .unorderedMeeting:
            "retrieval chunk resource fixture timestamps must increase strictly"
        case .mixedLanguageTurn:
            "retrieval chunk resource fixture contains a mixed-language complete turn"
        case .missingBilingualCoverage:
            "retrieval chunk resource fixture requires homogeneous English and Spanish turns"
        }
    }
}

struct RetrievalChunkResourceFixture: Decodable, Sendable {
    static let maximumByteCount = 8 * 1_024 * 1_024
    static let publicGeneration = "public-bilingual-homogeneous-v1"

    let schemaVersion: Int
    let kind: String
    let generation: String
    let contentSource: String
    let segments: [Segment]

    struct Segment: Decodable, Sendable {
        let id: String
        let meetingID: String
        let meetingTitle: String
        let timestampMilliseconds: Int
        let transcriptRevision: Int
        let language: String
        let owner: String
        let text: String
    }

    struct Coverage: Equatable, Sendable {
        let meetingCount: Int
        let sourceSegmentCount: Int
        let homogeneousEnglishTurnCount: Int
        let homogeneousSpanishTurnCount: Int

        var homogeneousTurnCount: Int {
            homogeneousEnglishTurnCount + homogeneousSpanishTurnCount
        }
    }

    static func load(from url: URL) throws -> Self {
        try loadSnapshot(from: url).fixture
    }

    static func loadSnapshot(
        from url: URL
    ) throws -> (fixture: Self, data: Data) {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw RetrievalChunkResourceFixtureError.unreadable
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: maximumByteCount + 1) ?? Data()
        } catch {
            throw RetrievalChunkResourceFixtureError.unreadable
        }
        guard data.count <= maximumByteCount else {
            throw RetrievalChunkResourceFixtureError.tooLarge
        }
        let fixture: Self
        do {
            fixture = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw RetrievalChunkResourceFixtureError.invalidJSON
        }
        _ = try fixture.coverage()
        return (fixture, data)
    }

    func coverage() throws -> Coverage {
        try validateRoot()
        let grouped = Dictionary(grouping: segments, by: \.meetingID)
        var languageTurnCounts = ["en": 0, "es": 0]
        for meeting in grouped.values {
            for language in try homogeneousTurnLanguages(in: meeting) {
                languageTurnCounts[language, default: 0] += 1
            }
        }

        let english = languageTurnCounts["en", default: 0]
        let spanish = languageTurnCounts["es", default: 0]
        guard english > 0,
              spanish > 0,
              languageTurnCounts.keys.allSatisfy({ ["en", "es"].contains($0) })
        else {
            throw RetrievalChunkResourceFixtureError.missingBilingualCoverage
        }
        return Coverage(
            meetingCount: grouped.count,
            sourceSegmentCount: segments.count,
            homogeneousEnglishTurnCount: english,
            homogeneousSpanishTurnCount: spanish)
    }

    private func validateRoot() throws {
        guard schemaVersion == 1,
              kind == "retrieval-chunk-resource-fixture",
              isSafeIdentifier(generation),
              ["public-synthetic-only", "private-anonymized"]
                .contains(contentSource),
              contentSource != "public-synthetic-only"
                || generation == Self.publicGeneration
        else {
            throw RetrievalChunkResourceFixtureError.unsupportedSchema
        }
        guard !segments.isEmpty, segments.count <= 10_000 else {
            throw RetrievalChunkResourceFixtureError.invalidBounds
        }
        guard Set(segments.map(\.id)).count == segments.count else {
            throw RetrievalChunkResourceFixtureError.repeatedIdentity
        }
        guard segments.allSatisfy(validSegment) else {
            throw RetrievalChunkResourceFixtureError.invalidSegment
        }
    }

    private func homogeneousTurnLanguages(
        in meeting: [Segment]
    ) throws -> [String] {
        guard Set(meeting.map(\.meetingTitle)).count == 1,
              Set(meeting.map(\.transcriptRevision)).count == 1,
              Set(meeting.map(\.owner)).count >= 2
        else {
            throw RetrievalChunkResourceFixtureError.inconsistentMeeting
        }
        let ordered = meeting.sorted {
            ($0.timestampMilliseconds, $0.id)
                < ($1.timestampMilliseconds, $1.id)
        }
        guard zip(ordered, ordered.dropFirst()).allSatisfy({ pair in
            pair.0.timestampMilliseconds < pair.1.timestampMilliseconds
        }) else {
            throw RetrievalChunkResourceFixtureError.unorderedMeeting
        }

        var languages: [String] = []
        var currentOwner: String?
        var currentLanguage: String?
        for segment in ordered {
            let language = primaryLanguage(segment.language)
            if currentOwner == segment.owner {
                guard currentLanguage == language else {
                    throw RetrievalChunkResourceFixtureError.mixedLanguageTurn
                }
            } else {
                if let currentLanguage { languages.append(currentLanguage) }
                currentOwner = segment.owner
                currentLanguage = language
            }
        }
        if let currentLanguage { languages.append(currentLanguage) }
        return languages
    }

    private func validSegment(_ segment: Segment) -> Bool {
        isSafeIdentifier(segment.id)
            && isSafeIdentifier(segment.meetingID)
            && isBoundedText(segment.meetingTitle, maximum: 200)
            && segment.timestampMilliseconds >= 0
            && segment.transcriptRevision >= 1
            && primaryLanguage(segment.language) != nil
            && isBoundedText(segment.owner, maximum: 120)
            && isBoundedText(segment.text, maximum: 2_000)
    }

    private func primaryLanguage(_ language: String) -> String? {
        let normalized = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard let primary = normalized.split(separator: "-").first.map(String.init),
              ["en", "es"].contains(primary)
        else { return nil }
        return primary
    }

    private func isSafeIdentifier(_ value: String) -> Bool {
        guard (1...80).contains(value.utf8.count),
              let first = value.utf8.first,
              (48...57).contains(first) || (97...122).contains(first)
        else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0)
                || (97...122).contains($0)
                || [45, 46, 95].contains($0)
        }
    }

    private func isBoundedText(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.count <= maximum
            && !value.contains("\0")
    }
}
