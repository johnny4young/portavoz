import Foundation
import NaturalLanguage

struct StatedPriorityToken {
    let text: String
    /// Lowercased, diacritic-folded, with typographic apostrophes made ASCII.
    let word: String
    /// Folded `NLTagger` lemma, or `word` when the tagger has none.
    let lemma: String
    let tag: NLTag?
    let range: Range<String.Index>

    var isVerb: Bool { tag == .verb }
    var isNoun: Bool { tag == .noun }
    var isPronoun: Bool { tag == .pronoun }
    var isDeterminer: Bool { tag == .determiner }
    var isModifier: Bool { tag == .adjective || tag == .adverb }
    var isPunctuation: Bool {
        guard let tag else { return false }
        return [
            .punctuation, .sentenceTerminator, .openQuote, .closeQuote, .openParenthesis,
            .closeParenthesis, .dash, .otherPunctuation, .wordJoiner
        ].contains(tag)
    }
    var isNegation: Bool { StatedPriorityLexicon.negations.contains(lemma) || word == "n't" }
    var isQualifier: Bool { !isVerb && matches(StatedPriorityLexicon.demotingQualifiers) }
    var isPromotingQualifier: Bool { !isVerb && matches(StatedPriorityLexicon.promotingQualifiers) }
    func matches(_ words: Set<String>) -> Bool { words.contains(word) || words.contains(lemma) }
}

struct StatedPrioritySentence {
    let captionID: String
    let text: String
    let tokens: [StatedPriorityToken]

    var isQuestion: Bool { text.contains("?") || text.contains("\u{BF}") }
    var span: StatedPrioritySpan { StatedPrioritySpan(captionID: captionID, quote: text) }

    func quote(_ range: Range<Int>) -> String {
        String(text[tokens[range.lowerBound].range.lowerBound..<tokens[range.upperBound - 1].range.upperBound])
    }

    /// Indices where `phrase` starts inside `range`, compared by folded word.
    func occurrences(of phrase: [String], in range: Range<Int>) -> [Int] {
        guard !phrase.isEmpty, range.count >= phrase.count else { return [] }
        return (range.lowerBound...(range.upperBound - phrase.count)).filter { start in
            phrase.indices.allSatisfy { tokens[start + $0].word == phrase[$0] }
        }
    }

    func contains(anyOf phrases: [[String]], in range: Range<Int>? = nil) -> Bool {
        phrases.contains { !occurrences(of: $0, in: range ?? tokens.indices).isEmpty }
    }
}

enum StatedPriorityText {
    static func fold(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func language(of captions: [StatedPriorityCaption]) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .spanish]
        recognizer.processString(captions.map(\.text).joined(separator: " "))
        return recognizer.dominantLanguage ?? .english
    }

    static func sentences(in text: String, language: NLLanguage) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.setLanguage(language)
        return tokenizer.tokens(for: text.startIndex..<text.endIndex)
            .map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func sentence(_ text: String, captionID: String, language: NLLanguage) -> StatedPrioritySentence {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        tagger.setLanguage(language, range: text.startIndex..<text.endIndex)
        var tokens: [StatedPriorityToken] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace]
        ) { tag, range in
            let word = fold(String(text[range]))
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0
                .map { fold($0.rawValue) }
            tokens.append(StatedPriorityToken(
                text: String(text[range]), word: word, lemma: lemma ?? word, tag: tag, range: range))
            return true
        }
        return StatedPrioritySentence(captionID: captionID, text: text, tokens: tokens)
    }
}

/// The captions as one ordered run of sentences, with the focal sentence kept
/// whole even where the sentence tokenizer would have cut it differently.
struct StatedPriorityTranscript {
    let sentences: [StatedPrioritySentence]
    let focalIndex: Int

    var focal: StatedPrioritySentence { sentences[focalIndex] }
    var previous: StatedPrioritySentence? { focalIndex > 0 ? sentences[focalIndex - 1] : nil }
    var following: ArraySlice<StatedPrioritySentence> { sentences[(focalIndex + 1)...] }

    init?(captions: [StatedPriorityCaption], focus: StatedPriorityFocus, language: NLLanguage) {
        var sentences: [StatedPrioritySentence] = []
        var focalIndex: Int?
        for caption in captions {
            let parts: [String]
            if caption.id == focus.captionID {
                guard let range = caption.text.range(of: focus.sentence),
                      caption.text.components(separatedBy: focus.sentence).count == 2
                else { return nil }
                let before = StatedPriorityText.sentences(
                    in: String(caption.text[..<range.lowerBound]), language: language)
                let after = StatedPriorityText.sentences(
                    in: String(caption.text[range.upperBound...]), language: language)
                focalIndex = sentences.count + before.count
                parts = before + [focus.sentence] + after
            } else {
                parts = StatedPriorityText.sentences(in: caption.text, language: language)
            }
            sentences += parts.map { StatedPriorityText.sentence($0, captionID: caption.id, language: language) }
        }
        guard let focalIndex else { return nil }
        self.sentences = sentences
        self.focalIndex = focalIndex
    }
}
