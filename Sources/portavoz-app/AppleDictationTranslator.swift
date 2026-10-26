import ApplicationKit
import Foundation
import Translation

/// The system translator, only for a language pair already on this Mac. A missing pair is
/// reported, never downloaded here; Settings owns the deliberate download.
struct AppleDictationTranslator: DictationTextTranslating {
    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let source = Locale.Language(identifier: source)
        let target = Locale.Language(identifier: target)
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed:
            break
        case .supported:
            throw DictationTranslationUnavailable(.notInstalled)
        default:
            throw DictationTranslationUnavailable(.unsupported)
        }
        let session = TranslationSession(installedSource: source, target: target)
        return try await session.translate(text).targetText
    }
}
