import ApplicationKit

/// Deterministic translator for disposable launches: it tags each line with its target.
struct MeetingTranslationFixture: TextTranslating {
    let isMissing: Bool

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        guard !isMissing else { throw TranslationUnavailable(.notInstalled) }
        return "[\(target)] \(text)"
    }
}
