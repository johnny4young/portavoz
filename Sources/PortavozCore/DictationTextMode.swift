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
    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, mode: DictationTextMode) {
        self.bundleIdentifier = bundleIdentifier
        self.mode = mode
    }
}
