import Foundation

/// Canonical primary BCP-47 language code used at policy boundaries.
/// Persisted transcript/summary rows remain strings for schema compatibility.
public struct LanguageCode: Codable, Hashable, Sendable {
    public let identifier: String

    private init(canonical identifier: String) {
        self.identifier = identifier
    }

    public init?(_ rawValue: String?) {
        let normalized = (rawValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard
            let primary = normalized.split(separator: "-").first,
            !primary.isEmpty,
            primary != "und"
        else { return nil }
        self.identifier = String(primary)
    }

    public static let english = LanguageCode(canonical: "en")
    public static let spanish = LanguageCode(canonical: "es")
}

/// Controls speech recognition only. It never chooses the language of a
/// generated summary or translates transcript text.
public enum TranscriptLanguagePolicy: Codable, Equatable, Sendable {
    case automatic
    case fixed(LanguageCode)

    public init(persistedValue: String?) {
        guard persistedValue != "auto", let language = LanguageCode(persistedValue) else {
            self = .automatic
            return
        }
        self = .fixed(language)
    }

    public var persistedValue: String {
        switch self {
        case .automatic: "auto"
        case .fixed(let language): language.identifier
        }
    }

    public var languageHint: String? {
        switch self {
        case .automatic: nil
        case .fixed(let language): language.identifier
        }
    }
}

/// Controls generated output only. Following the spoken language is the
/// least-surprising default; mixed/unknown meetings use the app locale.
public enum SummaryLanguagePolicy: Codable, Equatable, Sendable {
    case followSpokenLanguage
    case fixed(LanguageCode)

    public init(persistedValue: String?) {
        guard persistedValue != "spoken", let language = LanguageCode(persistedValue) else {
            self = .followSpokenLanguage
            return
        }
        self = .fixed(language)
    }

    public var persistedValue: String {
        switch self {
        case .followSpokenLanguage: "spoken"
        case .fixed(let language): language.identifier
        }
    }

    public func resolve(
        spokenLanguage: String?, fallbackLanguage: String?
    ) -> LanguageCode {
        switch self {
        case .fixed(let language):
            language
        case .followSpokenLanguage:
            LanguageCode(spokenLanguage) ?? LanguageCode(fallbackLanguage) ?? .english
        }
    }
}
