import Foundation
import PortavozCore
import TranscriptionKit

/// A closed portable vocabulary, deliberately unrelated to a defaults-domain dump.
/// Adding a case requires reviewing its activation, privacy and migration effects.
public enum PortableSettingsKey: String, CaseIterable, Codable, Sendable {
    case interfaceLanguage
    case recognitionLanguage
    case summaryLanguage
    case menuBarVisible
    case titleTemplate
    case vocabulary
    case dictationLanguage
    case removeFillers
    case replacements
}

public enum PortableSettingsValue: Codable, Equatable, Sendable {
    case text(String)
    case flag(Bool)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .flag(flag)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .flag(let value): try container.encode(value)
        }
    }
}

public enum PortableSettingsFailure: Error, Equatable, Sendable {
    case invalidFile
    case unsupportedVersion
    case unsupportedSetting
    case invalidValue
    case tooLarge
    case staleReview
    case captureActive
}

public enum PortableSettingsValidation {
    public static let maximumFileBytes = 1_048_576
    public static let maximumTextBytes = 65_536

    public static func validate(_ values: [PortableSettingsKey: PortableSettingsValue]) throws {
        for (key, value) in values {
            switch (key, value) {
            case (.menuBarVisible, .flag), (.removeFillers, .flag): break
            case (.menuBarVisible, _), (.removeFillers, _): throw PortableSettingsFailure.invalidValue
            case (_, .flag): throw PortableSettingsFailure.invalidValue
            case (_, .text(let text)):
                guard text.utf8.count <= maximumTextBytes, !text.contains("\0") else {
                    throw PortableSettingsFailure.invalidValue
                }
                try validateText(text, for: key)
            }
        }
    }

    private static func validateText(_ text: String, for key: PortableSettingsKey) throws {
        switch key {
        case .interfaceLanguage:
            guard ["system", "en", "es"].contains(text) else { throw PortableSettingsFailure.invalidValue }
        case .dictationLanguage:
            guard ["auto", "en", "es"].contains(text) else { throw PortableSettingsFailure.invalidValue }
        case .recognitionLanguage:
            try validateLanguage(text, following: "auto")
        case .summaryLanguage:
            try validateLanguage(text, following: "spoken")
        case .replacements:
            _ = try replacements(text)
        case .titleTemplate, .vocabulary: break
        case .menuBarVisible, .removeFillers: throw PortableSettingsFailure.invalidValue
        }
    }

    private static func validateLanguage(_ value: String, following: String) throws {
        if value == following { return }
        guard let language = LanguageCode(value), language.identifier == value,
              (2...3).contains(value.utf8.count), value.utf8.allSatisfy({ (97...122).contains($0) })
        else { throw PortableSettingsFailure.invalidValue }
    }

    static func replacements(_ text: String) throws -> [DictationReplacement] {
        // The normal settings codec deliberately salvages legacy malformed data.
        // An imported file must instead disclose failure, never silently erase rules.
        guard let data = text.data(using: .utf8),
              let values = try? JSONDecoder().decode([DictationReplacement].self, from: data),
              values.count <= 1_000 else { throw PortableSettingsFailure.invalidValue }
        let canonical = DictationTextRules.canonical(values)
        guard canonical.count == values.count else { throw PortableSettingsFailure.invalidValue }
        return canonical
    }
}
