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
    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, mode: DictationTextMode, polishRecipeID: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.mode = mode
        self.polishRecipeID = mode == .polish ? polishRecipeID : nil
    }

    public var choice: DictationTextChoice { DictationTextChoice(mode: mode, recipeID: polishRecipeID) }
}
