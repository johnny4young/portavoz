/// A post-recognition choice. Literal and clean are deterministic; polish is the one
/// generative mode, chosen explicitly, and always starts from the clean text.
public enum DictationTextMode: String, Codable, CaseIterable, Sendable {
    case literal
    case clean
    case polish

    /// Polish runs the clean rules first, so the deterministic tier applies to both.
    public var appliesCleanRules: Bool { self != .literal }
}

/// Only application identity is durable; window titles, URLs and editor contents are not profiles.
public struct DictationApplicationTextProfile: Codable, Equatable, Identifiable, Sendable {
    public let bundleIdentifier: String
    public var mode: DictationTextMode
    /// The Polish recipe for this application; nil is the conservative copy edit.
    public var polishRecipeID: String?
    /// Nil follows the default translation; `.off` keeps this application untranslated.
    public var translationTarget: DictationTranslationTarget?
    public var id: String { bundleIdentifier }

    public init(
        bundleIdentifier: String, mode: DictationTextMode, polishRecipeID: String? = nil,
        translationTarget: DictationTranslationTarget? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.mode = mode
        self.polishRecipeID = mode == .polish ? polishRecipeID : nil
        self.translationTarget = translationTarget
    }

    public var choice: DictationTextChoice { DictationTextChoice(mode: mode, recipeID: polishRecipeID) }
}

/// Where dictated text is translated before it is pasted. Off and the two recognized languages only.
public enum DictationTranslationTarget: String, Codable, CaseIterable, Sendable {
    case off
    case english = "en"
    case spanish = "es"

    /// The BCP-47 language the translator produces, or nil when off.
    public var languageCode: String? { self == .off ? nil : rawValue }
}
