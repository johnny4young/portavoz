import ApplicationKit
import Testing
import TranscriptionKit

struct TranslateDictationTests {
    private struct Translator: DictationTextTranslating {
        let reply: @Sendable (String, String, String) async throws -> String

        func translate(_ text: String, from source: String, to target: String) async throws -> String {
            try await reply(text, source, target)
        }
    }

    private struct Failure: Error {}

    private func translate(
        _ text: String, source: String?, target: String = "en", timeout: Duration = .seconds(5),
        reply: @escaping @Sendable (String, String, String) async throws -> String
    ) async -> DictationTranslationOutcome {
        await TranslateDictation(translator: Translator(reply: reply), timeout: timeout)(
            text, source: source, target: target)
    }

    @Test
    func aTranslationIsPastedTrimmed() async {
        let outcome = await translate("No borres estas notas.", source: "es") { text, source, target in
            #expect(text == "No borres estas notas.")
            #expect(source == "es" && target == "en")
            return "  Don't delete these notes.\n"
        }
        #expect(outcome == .translated("Don't delete these notes."))
    }

    @Test
    func theSameOrAnUnknownLanguageNeverReachesTheTranslator() async {
        let same = await translate("Don't delete these notes.", source: "en") { _, _, _ in
            Issue.record("called"); return ""
        }
        #expect(same == .kept(.sameLanguage))
        let unknown = await translate("ok", source: nil) { _, _, _ in Issue.record("called"); return "" }
        #expect(unknown == .kept(.unknownLanguage))
    }

    @Test
    func missingAndUnsupportedLanguagesKeepTheirReason() async {
        let missing = await translate("No borres estas notas.", source: "es") { _, _, _ in
            throw DictationTranslationUnavailable(.notInstalled)
        }
        #expect(missing == .kept(.notInstalled))
        let unsupported = await translate("No borres estas notas.", source: "es") { _, _, _ in
            throw DictationTranslationUnavailable(.unsupported)
        }
        #expect(unsupported == .kept(.unsupported))
    }

    @Test
    func aFailureOrEmptyReplyKeepsTheText() async {
        let failed = await translate("No borres estas notas.", source: "es") { _, _, _ in throw Failure() }
        #expect(failed == .kept(.failed))
        let empty = await translate("No borres estas notas.", source: "es") { _, _, _ in "  " }
        #expect(empty == .kept(.failed))
    }

    @Test
    func aSlowTranslatorTimesOut() async {
        let slow = "No borres estas notas."
        let outcome = await translate(slow, source: "es", timeout: .milliseconds(50)) { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return "late"
        }
        #expect(outcome == .kept(.timedOut))
    }

    @Test
    func dictationLanguageTellsEnglishFromSpanishAndGivesUpOnShortText() {
        #expect(SpokenLanguageDetector.dictationLanguage(in: "No borres estas notas, por favor.") == "es")
        #expect(SpokenLanguageDetector.dictationLanguage(in: "Please don't delete these notes.") == "en")
        #expect(SpokenLanguageDetector.dictationLanguage(in: "ok sí") == nil)
    }
}
