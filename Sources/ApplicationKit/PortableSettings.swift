import Foundation
import PortavozCore

/// A closed portable vocabulary, deliberately unrelated to a defaults-domain dump.
/// Adding a case requires reviewing its activation, privacy and migration effects.
public enum PortableSettingsKey: String, CaseIterable, Codable, Sendable {
    case interfaceLanguage
    case recognitionLanguage
    case summaryLanguage
    case menuBarVisible
    case titleTemplate
    case vocabulary

    /// Keys a 1.x export wrote for dictation, which has left the app; import skips them.
    public static let retiredRawValues: Set<String> = ["dictationLanguage", "removeFillers", "replacements"]
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
            case (.menuBarVisible, .flag): break
            case (.menuBarVisible, _): throw PortableSettingsFailure.invalidValue
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
        case .recognitionLanguage:
            try validateLanguage(text, following: "auto")
        case .summaryLanguage:
            try validateLanguage(text, following: "spoken")
        case .titleTemplate, .vocabulary: break
        case .menuBarVisible: throw PortableSettingsFailure.invalidValue
        }
    }

    private static func validateLanguage(_ value: String, following: String) throws {
        if value == following { return }
        guard let language = LanguageCode(value), language.identifier == value,
              (2...3).contains(value.utf8.count), value.utf8.allSatisfy({ (97...122).contains($0) })
        else { throw PortableSettingsFailure.invalidValue }
    }
}
