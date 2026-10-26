import AppKit
import NaturalLanguage
import TranscriptionKit

/// Matches the first dictated word's case to the sentence before the caret. Opt-in:
/// lowering a capital is done only for a word the system dictionary knows in lowercase
/// and that is not a name, an acronym, "I" or one of the user's own spellings.
@MainActor
struct DictationCaretCase {
    nonisolated static let defaultsKey = "dictationCaretCase"
    /// UTF-16 units read before the caret, only while the field is revalidated; never kept.
    nonisolated static let contextLength = 80

    enum Position: Equatable { case sentenceStart, midSentence, unknown }

    // Escaped so the English-source guard does not read them as Spanish prose.
    private static let openers: Set<Character> = ["(", "[", "{", "\u{BF}", "\u{A1}", "“", "‘", "«", "\"", "'"]
    private static let closers: Set<Character> = [")", "]", "}", "»", "”", "’", "\"", "'"]
    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…"]
    private static let continues: Set<Character> = [",", ";"]
    private static let abbreviations: Set<String> = [
        "e.g.", "i.e.", "etc.", "vs.", "dr.", "dra.", "mr.", "mrs.", "ms.", "sr.", "sra.", "srta.",
        "st.", "no.", "p.ej.", "ej.", "ud.", "uds.", "approx.", "aprox."
    ]

    /// Spellings the user chose in the text replacements; never recased.
    var protectedWords: Set<String> = []
    var isCommonWord: @MainActor (String) -> Bool = Self.systemDictionaryKnows
    var isName: @MainActor (_ word: String, _ sentence: String) -> Bool = Self.taggedAsName

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    /// Nil while the setting is off, so only the two characters of D560 are read.
    @MainActor
    static func live(_ defaults: UserDefaults = .standard) -> Self? {
        guard isEnabled(in: defaults) else { return nil }
        let rules = DictationTextRules.decode(
            replacements: defaults.string(forKey: DictationController.replacementsKey) ?? "")
        return Self(protectedWords: Set(rules.flatMap { $0.replacement.split(separator: " ").map(String.init) }))
    }

    /// - Parameter atFieldStart: true when `preceding` reaches the start of the field.
    static func position(after preceding: String, atFieldStart: Bool) -> Position {
        var text = Substring(preceding)
        let blank = text.reversed().prefix { $0.isWhitespace }
        if blank.contains(where: \.isNewline) { return .sentenceStart }
        text = text.dropLast(blank.count)
        while let last = text.last, openers.contains(last) { text = text.dropLast() }
        text = Substring(text.reversed().drop(while: \.isWhitespace).reversed())
        guard let last = text.last else { return atFieldStart ? .sentenceStart : .unknown }
        if sentenceEnds.contains(last) {
            let token = text.split(whereSeparator: \.isWhitespace).last.map { $0.lowercased() } ?? ""
            let bare = token.drop { openers.contains($0) }
            return abbreviations.contains(String(bare)) || isInitial(bare) ? .unknown : .sentenceStart
        }
        if closers.contains(last) { return .unknown }
        return last.isLetter || last.isNumber || continues.contains(last) ? .midSentence : .unknown
    }

    func adapt(_ text: String, after preceding: String, atFieldStart: Bool) -> String {
        guard let start = text.firstIndex(where: { !Self.openers.contains($0) && !$0.isWhitespace }),
              text[start].isLetter else { return text }
        let word = String(text[start...].prefix { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" })
        switch Self.position(after: preceding, atFieldStart: atFieldStart) {
        case .sentenceStart:
            guard text[start].isLowercase else { return text }
            return text.replacingCharacters(in: start...start, with: text[start].uppercased())
        case .midSentence:
            guard keepsCapital(word, sentence: preceding + " " + text) == false else { return text }
            return text.replacingCharacters(in: start...start, with: text[start].lowercased())
        case .unknown:
            return text
        }
    }

    private func keepsCapital(_ word: String, sentence: String) -> Bool {
        guard let first = word.first, first.isUppercase else { return true }
        let rest = word.dropFirst()
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return true }
        if rest.contains(where: \.isUppercase) { return true }
        if protectedWords.contains(word) { return true }
        return !isCommonWord(word.lowercased()) || isName(word, sentence)
    }

    /// "J." in "J. Smith" ends no sentence.
    private static func isInitial(_ token: Substring) -> Bool {
        token.count == 2 && token.first?.isLetter == true
    }

    @MainActor
    static func systemDictionaryKnows(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        return ["en", "es"].contains { language in
            checker.availableLanguages.contains(language)
                && checker.checkSpelling(
                    of: word, startingAt: 0, language: language, wrap: false,
                    inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }

    static func taggedAsName(_ word: String, in sentence: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = sentence
        var named = false
        tagger.enumerateTags(
            in: sentence.startIndex..<sentence.endIndex, unit: .word, scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag),
               sentence[range].split(separator: " ").contains(where: { $0 == word }) {
                named = true
                return false
            }
            return true
        }
        return named
    }
}
