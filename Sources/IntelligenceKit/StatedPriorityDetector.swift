import Foundation

/// One meeting-level priority somebody stated out loud, with the exact caption
/// it came from.
public struct StatedPriority: Identifiable, Sendable, Equatable {
    public let id: UUID
    /// What was named as the priority, bounded to the clause that named it.
    public let subject: String
    /// The caption the subject was read from, verbatim — the evidence.
    public let statement: String
    /// The caption row, so the offer can be cited and played back.
    public let sourceRowID: UUID
    /// Seconds since the recording started.
    public let statedAt: TimeInterval

    public init(
        id: UUID = UUID(),
        subject: String,
        statement: String,
        sourceRowID: UUID,
        statedAt: TimeInterval
    ) {
        self.id = id
        self.subject = subject
        self.statement = statement
        self.sourceRowID = sourceRowID
        self.statedAt = statedAt
    }

    /// Case- and diacritic-insensitive identity, so restating the same
    /// priority is not offered a second time.
    public var subjectKey: String {
        subject
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Detects a priority somebody **declared**, never one the meeting merely
/// emphasized.
///
/// Field evidence (Sep 2026): a real standup opened by declaring its priority
/// and later put everything else on hold. The transcript held all of it
/// verbatim, the summary reduced it to a per-person status line, and the
/// meeting produced no action items — a stated priority is not a decision, an
/// action item, a commitment or a topic, so it had nowhere to live (GAPS #13).
/// Over that meeting's 305 finalized segments this detector fires once, on the
/// line that declared the priority, and on nothing else.
///
/// Deterministic on purpose, like `TurnEndpointPolicy` (D138) and the D26
/// "asked you" gate. A model asked "what is the priority here?" will always
/// answer something, and a confident wrong priority is worse than none: it
/// would reorder the user's meeting around a phrase somebody stressed. So the
/// contract is narrow and fails closed — an explicit copular statement naming a
/// bounded subject, or nothing.
///
/// Deliberately **out of scope**: "let's focus on X", "X first", "everything
/// else on hold". Each is a real signal in the same field transcript, and each
/// is also ordinary meeting emphasis. They need evidence that emphasis was
/// meant as a priority, which this detector cannot have.
public enum StatedPriorityDetector {
    /// A subject longer than this is a sentence, not a thing to prioritize.
    public static let maximumSubjectCharacters = 80
    public static let maximumSubjectWords = 8
    /// Tokens allowed between the priority noun and its copula, so "the
    /// priority right now is X" reads as one anchor.
    public static let maximumAnchorGap = 4

    private static let priorityNouns: Set<String> = [
        "priority", "priorities", "prioridad", "prioridades"
    ]
    /// Present tense only. "The priority was X" may be history, and history
    /// re-prioritizes nothing.
    private static let copulas: Set<String> = ["is", "are", "es", "son"]
    private static let negations: Set<String> = [
        "not", "no", "never", "nunca", "tampoco", "ni", "isn", "aren"
    ]
    /// A hypothetical priority is not a stated one.
    private static let conditionals: Set<String> = [
        "if", "unless", "whether", "suppose", "would", "were", "should", "si"
    ]
    private static let conjunctions: Set<String> = [
        "and", "or", "but", "so", "because", "while",
        "y", "o", "pero", "porque", "mientras", "aunque"
    ]
    /// A subject made only of these names nothing.
    private static let fillers: Set<String> = [
        "it", "that", "this", "these", "those", "the", "a", "an", "to", "of",
        "for", "in", "on", "we", "us", "them",
        "eso", "esto", "esa", "ese", "lo", "la", "el", "los", "las", "de",
        "en", "para", "que", "nos"
    ]

    /// The stated priority in one finalized caption, or nil — which is the
    /// common answer.
    public static func detect(
        in text: String,
        rowID: UUID,
        statedAt: TimeInterval
    ) -> StatedPriority? {
        // Asking what the priority is states nothing.
        guard !QuestionHeuristic.looksLikeQuestion(text) else { return nil }
        let tokens = tokenize(text)
        guard let anchor = tokens.indices.first(where: {
            priorityNouns.contains(tokens[$0].lowered)
        }) else { return nil }
        guard !isHypothetical(tokens, before: anchor) else { return nil }

        let subject = forwardSubject(tokens, anchor: anchor)
            ?? backwardSubject(tokens, anchor: anchor)
        guard let subject, let phrase = validated(subject) else { return nil }
        return StatedPriority(
            subject: phrase,
            statement: text.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceRowID: rowID,
            statedAt: statedAt)
    }
}

// MARK: - Anchors

private extension StatedPriorityDetector {
    /// "<priority> [right now] is <SUBJECT>"
    static func forwardSubject(_ tokens: [Token], anchor: Int) -> [Token]? {
        var copula: Int?
        var index = anchor
        while index + 1 < tokens.count, index - anchor < maximumAnchorGap {
            if tokens[index].closesClause { return nil }
            index += 1
            if negations.contains(tokens[index].lowered) { return nil }
            if copulas.contains(tokens[index].lowered) {
                copula = index
                break
            }
        }
        guard let copula, copula + 1 < tokens.count else { return nil }
        guard !negations.contains(tokens[copula + 1].lowered) else { return nil }
        var subject: [Token] = []
        var cursor = copula + 1
        while cursor < tokens.count {
            let token = tokens[cursor]
            if conjunctions.contains(token.lowered) { break }
            // Running past the cap means the clause never named a subject; a
            // truncated one would read as a priority nobody stated.
            if subject.count == maximumSubjectWords { return nil }
            subject.append(token)
            if token.closesClause { break }
            cursor += 1
        }
        return subject.isEmpty ? nil : subject
    }

    /// "<SUBJECT> is [the top] <priority>"
    static func backwardSubject(_ tokens: [Token], anchor: Int) -> [Token]? {
        var copula: Int?
        var index = anchor
        while index > 0, anchor - index < maximumAnchorGap {
            index -= 1
            if negations.contains(tokens[index].lowered) { return nil }
            if tokens[index].closesClause { return nil }
            if copulas.contains(tokens[index].lowered) {
                copula = index
                break
            }
        }
        guard let copula, copula > 0 else { return nil }
        var subject: [Token] = []
        var cursor = copula - 1
        while cursor >= 0 {
            let token = tokens[cursor]
            if conjunctions.contains(token.lowered) { break }
            if subject.count == maximumSubjectWords { return nil }
            subject.insert(token, at: 0)
            // The clause flag sits on the token the punctuation follows, so a
            // break before the subject stops the walk after including nothing
            // more.
            if cursor > 0, tokens[cursor - 1].closesClause { break }
            cursor -= 1
        }
        return subject.isEmpty ? nil : subject
    }

    /// A conditional or modal anywhere in the clause leading to the anchor.
    static func isHypothetical(_ tokens: [Token], before anchor: Int) -> Bool {
        var index = anchor
        while index > 0 {
            index -= 1
            if conditionals.contains(tokens[index].lowered) { return true }
            if tokens[index].closesClause { return false }
        }
        return false
    }

    static func validated(_ subject: [Token]) -> String? {
        let phrase = subject.map(\.text).joined(separator: " ")
        guard phrase.count >= 2, phrase.count <= maximumSubjectCharacters
        else { return nil }
        // At least one content word: "the priority is that" names nothing.
        guard subject.contains(where: {
            $0.lowered.count >= 3 && !fillers.contains($0.lowered)
        }) else { return nil }
        return phrase
    }
}

// MARK: - Tokens

private extension StatedPriorityDetector {
    struct Token {
        let text: String
        let lowered: String
        /// True when clause punctuation follows this token.
        let closesClause: Bool
    }

    static let clauseBreakers: Set<Character> = [
        ",", ".", ";", ":", "?", "!", "\u{2014}", "\u{2013}", "\u{2026}",
        // Inverted marks open a Spanish clause, so they close the one before.
        // Escaped so the English-prose ratchet reads punctuation, not prose.
        "\u{00BF}", "\u{00A1}"
    ]

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(Token(
                text: current, lowered: current.lowercased(), closesClause: false))
            current = ""
        }
        for character in text {
            if character.isLetter || character.isNumber
                || character == "-" || character == "'" || character == "\u{2019}" {
                current.append(character)
                continue
            }
            flush()
            guard clauseBreakers.contains(character), let last = tokens.popLast()
            else { continue }
            tokens.append(Token(
                text: last.text, lowered: last.lowered, closesClause: true))
        }
        flush()
        return tokens
    }
}
