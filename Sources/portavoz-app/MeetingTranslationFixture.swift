import ApplicationKit

/// Deterministic translator for disposable launches: it tags each line with its target.
struct MeetingTranslationFixture: DictationTextTranslating {
    let isMissing: Bool

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        guard !isMissing else { throw DictationTranslationUnavailable(.notInstalled) }
        return "[\(target)] \(text)"
    }
}
