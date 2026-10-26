import Foundation

/// Rewrites one dictated text conservatively: grammar, punctuation, fillers and false
/// starts only, in the same language and word order. The caller validates the result.
/// A `recipe` is the user's own instruction about form; nil is the conservative copy edit.
public protocol DictationTextPolishing: Sendable {
    func polish(_ text: String, recipe: String?) async throws -> String
}

extension DictationTextPolishing {
    public func polish(_ text: String) async throws -> String {
        try await polish(text, recipe: nil)
    }
}

/// The selected engine cannot run now; the caller keeps the clean text and shows `reason`.
public struct DictationPolishUnavailable: Error, Equatable, Sendable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}
