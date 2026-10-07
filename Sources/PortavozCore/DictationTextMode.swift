/// An explicit deterministic post-recognition choice, never a generative requirement.
public enum DictationTextMode: String, Codable, CaseIterable, Sendable {
    case literal
    case clean
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
