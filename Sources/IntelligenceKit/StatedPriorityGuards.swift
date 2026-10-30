import Foundation

/// Shapes that carry the priority vocabulary without asserting a current
/// priority: reported, hypothetical, past or future, uncertain, or addressed
/// to an assistant.
enum StatedPriorityGuards {
    typealias Lexicon = StatedPriorityLexicon

    private static let spanishImperatives: Set<String> = [
        "ignorar", "marcar", "etiquetar", "anotar", "apuntar", "registrar", "guardar", "poner",
        "agregar", "anadir", "tratar"
    ]

    static func addressesAssistant(_ sentence: StatedPrioritySentence) -> Bool {
        if sentence.tokens.contains(where: { $0.matches(Lexicon.assistantWords) }) { return true }
        guard let first = sentence.tokens.first(where: {
            !$0.isPunctuation && !$0.matches(Lexicon.discourseMarkers)
        }), first.isVerb, first.matches(Lexicon.assistantImperatives) else { return false }
        // English imperatives are the bare lemma; a Spanish one is conjugated, so
        // an infinitive subject ("Marcar X, es la prioridad") is not an order.
        return spanishImperatives.contains(first.lemma) ? first.word != first.lemma : first.word == first.lemma
    }

    /// The abstention a sentence earns before any claim in it is read, looking
    /// only outside the claim's own target so a target's wording cannot veto it.
    static func nonAssertion(
        _ sentence: StatedPrioritySentence, excluding target: Range<Int>?
    ) -> StatedPriorityAbstention? {
        let outside = sentence.tokens.indices.filter { target?.contains($0) != true }.map { sentence.tokens[$0] }
        if isUncertain(sentence) { return .classifiedNeutral }
        if sentence.text.contains(where: { "\"“”«»".contains($0) })
            || outside.contains(where: { $0.matches(Lexicon.reportingWords) }) {
            return .classifiedNeutral
        }
        let irrealis = outside.contains {
            $0.text.lowercased() == "si" || Lexicon.hypotheticalWords.contains($0.word)
                || Lexicon.futureWords.contains($0.word) || Lexicon.pastWords.contains($0.word)
        }
        if irrealis || sentence.contains(anyOf: Lexicon.hypotheticalPhrases + Lexicon.futurePhrases) {
            return .classifiedNeutral
        }
        // Counted over the whole sentence: "It's not that X isn't a priority" hides one inside the subject.
        return negations(in: sentence.tokens) >= 2 ? .lowConfidence : nil
    }

    /// Spoken doubt or reversal ("not sure", "or not", and their Spanish forms) leaves the claim open.
    private static func isUncertain(_ sentence: StatedPrioritySentence) -> Bool {
        let tokens = sentence.tokens
        if tokens.contains(where: { $0.matches(Lexicon.uncertaintyWords) }), tokens.contains(where: \.isNegation) {
            return true
        }
        if sentence.contains(anyOf: Lexicon.reversalPhrases) { return true }
        return tokens.indices.dropLast().contains {
            tokens[$0].word == "o" && tokens[$0 + 1].text.lowercased() == "s\u{ED}"
        }
    }

    /// Negations, not counting an interjected "No," at either edge of a phrase.
    private static func negations(in tokens: [StatedPriorityToken]) -> Int {
        tokens.indices.filter { index in
            guard tokens[index].isNegation else { return false }
            guard tokens[index].word == "no" else { return true }
            let before = index == 0 || tokens[index - 1].isPunctuation
            let after = index == tokens.count - 1 || tokens[index + 1].isPunctuation
            return !(before || after)
        }.count
    }
}
