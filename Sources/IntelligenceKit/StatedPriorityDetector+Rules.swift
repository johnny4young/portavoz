import Foundation

/// Vocabulary and shapes the priority detector admits, kept apart from the
/// scanning itself so each rule can be read and argued with on its own.
///
/// Every entry here declares precedence outright. Nothing on this list is an
/// intensifier, an opinion or a topic that came up a lot — the D505 spike
/// showed what happens when a reader is allowed to infer priority from
/// salience: an on-device model proposed 26 priorities for a meeting whose
/// transcript never once says the word.
///
/// Deliberately absent, so the omissions are not read as oversights:
///
/// - "lo primero es X" — usually sequence ("first we open the app"), not
///   precedence. Ambiguous in exactly the way this detector must not be.
/// - "let's focus on X", "X first", "everything else on hold" — real signals
///   in the field transcript, and also ordinary emphasis. Admitting them needs
///   evidence that the emphasis was meant as precedence.
/// - Cross-turn coreference ("that is the priority", three turns after the
///   subject was named). Resolving it is guesswork without a model.
enum PriorityVocabulary {
    /// Copular anchors: `<anchor> is <SUBJECT>` and `<SUBJECT> is <anchor>`.
    /// Longer phrases are matched before shorter ones at the same position.
    ///
    /// Written without diacritics on purpose: matching folds them, so one
    /// spelling covers both, and Spanish recognizer output that drops an accent
    /// is read the same as output that keeps it.
    static let anchors: [[String]] = [
        ["priority"], ["priorities"],
        ["prioridad"], ["prioridades"],
        ["the", "most", "important", "thing"],
        ["most", "important", "thing"],
        ["lo", "mas", "importante"],
        ["the", "focus"],
        ["el", "foco"],
        ["number", "one"],
        ["numero", "uno"]
    ]

    /// `<SUBJECT> <phrase>` — precedence asserted by a verb rather than a noun.
    static let precedenceVerbPhrases: [[String]] = [
        ["takes", "precedence"],
        ["take", "precedence"],
        ["comes", "first"],
        ["come", "first"],
        ["goes", "first"],
        ["va", "primero"],
        ["van", "primero"],
        ["viene", "primero"]
    ]

    /// Qualifiers that DEMOTE the anchor. "The dashboard is a low priority"
    /// names what does **not** take precedence; reading it as a priority
    /// inverts the speaker. Spanish postposes most of these
    /// ("una prioridad baja"), so both sides of the anchor are inspected.
    static let demoting: Set<String> = [
        "low", "lower", "lowest", "least", "less", "minor", "secondary", "last",
        "baja", "bajo", "bajas", "menor", "menores", "secundaria", "segunda",
        "ultima", "ultimas"
    ]

    /// Present tense only. "The priority was X" may be history, and history
    /// re-prioritizes nothing.
    static let copulas: Set<String> = ["is", "are", "es", "son"]

    /// The tokenizer keeps apostrophes inside words, so contractions are
    /// matched whole rather than as a clipped stem.
    static let negations: Set<String> = [
        "not", "no", "never", "nunca", "tampoco", "ni",
        "isn't", "aren't", "doesn't", "don't", "won't", "can't", "wasn't"
    ]

    /// Clause-initial words that make the clause a question. Kept here, and
    /// matched UNFOLDED, because Spanish accents are exactly what separate the
    /// accented interrogative from its unaccented everyday twin.
    /// Borrowing `QuestionHeuristic`'s list was wrong: it is calibrated to
    /// over-admit for a classifier that prunes afterwards, and it carries
    /// "por", which silently dropped "Por ahora la prioridad es X".
    static let clauseInitialInterrogatives: Set<String> = [
        "what", "which", "who", "whom", "whose", "how", "why", "when", "where",
        "is", "are", "do", "does", "did", "can", "could", "would", "should",
        // Escaped so the English-prose ratchet reads vocabulary data, not prose.
        "qu\u{00E9}", "cu\u{00E1}l", "cu\u{00E1}les", "qui\u{00E9}n", "qui\u{00E9}nes",
        "c\u{00F3}mo", "cu\u{00E1}ndo", "d\u{00F3}nde", "ad\u{00F3}nde", "es", "son"
    ]

    /// A hypothetical priority is not a stated one.
    static let conditionals: Set<String> = [
        "if", "unless", "whether", "suppose", "would", "were", "should", "si"
    ]

    static let conjunctions: Set<String> = [
        "and", "or", "but", "so", "because", "while",
        "y", "o", "pero", "porque", "mientras", "aunque"
    ]

    /// A subject made only of these names nothing.
    static let fillers: Set<String> = [
        "it", "that", "this", "these", "those", "the", "a", "an", "to", "of",
        "for", "in", "on", "we", "us", "them", "low", "high",
        "eso", "esto", "esa", "ese", "esta", "estas", "estos", "aquel",
        "aquella", "aquello", "lo", "la", "el", "los", "las", "de",
        "en", "para", "que", "nos", "aqui", "ahi"
    ]

}
