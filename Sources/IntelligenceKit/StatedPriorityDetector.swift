import Foundation

/// One meeting-level priority somebody stated out loud, with the exact caption
/// it came from.
public struct StatedPriority: Identifiable, Sendable, Equatable {
    public let id: UUID
    /// What was named as the priority, bounded to the clause that named it.
    public let subject: String
    /// The caption the subject was read from, verbatim — the evidence. When a
    /// sentence spans several captions this is the joined text.
    public let statement: String
    /// The caption row carrying the declaration, so the offer can be cited and
    /// played back.
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

/// One finalized caption offered to the scanner.
public struct PriorityScanCaption: Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let startTime: TimeInterval
    /// Captions join only within the same channel and speaker, so a sentence is
    /// never assembled out of two people's words.
    public let channel: String
    public let speaker: String?

    public init(
        id: UUID,
        text: String,
        startTime: TimeInterval,
        channel: String,
        speaker: String? = nil
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.channel = channel
        self.speaker = speaker
    }
}

/// Detects a priority somebody **declared**, never one the meeting merely
/// emphasized.
///
/// Field evidence (Sep 2026): a real standup declared its priority and later
/// put everything else on hold. The transcript held all of it verbatim, the
/// summary reduced it to a per-person status line, and the meeting produced no
/// action items — a stated priority is not a decision, an action item, a
/// commitment or a topic, so it had nowhere to live (GAPS #13).
///
/// Deterministic on purpose, like `TurnEndpointPolicy` (D138) and the D26
/// "asked you" gate — and now with measurements behind that choice. The D505
/// spike gave these same meetings to Apple's on-device model behind guided
/// generation and a grounding gate: it proposed 26 priorities for a meeting
/// whose transcript never says the word, none of them correct. Guided
/// generation constrains the shape of an answer, not its truth, and the
/// grounding gate verifies provenance, not whether the cited line declares
/// anything. So the contract stays narrow and fails closed: an explicit
/// declaration of precedence naming a bounded subject, or nothing.
public enum StatedPriorityDetector {
    /// A subject longer than this is a sentence, not a thing to prioritize.
    public static let maximumSubjectCharacters = 80
    public static let maximumSubjectWords = 8
    /// Tokens allowed between the anchor and its copula, so "the priority
    /// right now is X" reads as one anchor.
    public static let maximumAnchorGap = 4
    /// Captions joined when one sentence is split across rows.
    public static let maximumJoinedCaptions = 3
    /// How far back joining may reach. Speech fragments arrive seconds apart;
    /// a longer reach starts assembling unrelated turns.
    public static let maximumJoinSeconds: TimeInterval = 15

    /// The stated priority in one finalized caption, or nil — which is the
    /// common answer.
    public static func detect(
        in text: String,
        rowID: UUID,
        statedAt: TimeInterval
    ) -> StatedPriority? {
        guard let subject = subject(in: text) else { return nil }
        return StatedPriority(
            subject: subject,
            statement: text.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceRowID: rowID,
            statedAt: statedAt)
    }

    /// Live speech splits one sentence across rows — "So the priority." /
    /// "Yeah." / "It's the share link." A single-caption scan sees none of it.
    /// The newest caption is tried alone first, then joined with its immediate
    /// predecessors from the same speaker and channel.
    ///
    /// `captions` is oldest-first; only the tail is considered.
    public static func detect(inRecent captions: [PriorityScanCaption]) -> StatedPriority? {
        guard let newest = captions.last else { return nil }
        if let alone = detect(
            in: newest.text, rowID: newest.id, statedAt: newest.startTime) {
            return alone
        }
        let window = joinableTail(of: captions)
        guard window.count > 1 else { return nil }
        // Joining is for FRAGMENTS: it may supply the missing copula or the
        // missing subject, never extend a clause that already has both. On a
        // real transcript, "la prioridad es esta." is complete but vacuous —
        // its subject is correctly rejected — and joining it to the next row
        // manufactured a long, meaningless subject out of the neighbour's
        // words. A caption whose anchor already has its copula is left alone.
        guard window.dropLast().allSatisfy({ !hasCompleteClause($0.text) })
        else { return nil }
        // The period the recognizer put at the end of "So the priority." is an
        // artifact of a fragmented utterance, not a sentence end. Joining rows
        // while keeping those seams accomplishes nothing, so they come off —
        // only at the seams, never inside a caption, and never a "?" or "!",
        // which are real enough to keep their meaning.
        let joined = window.enumerated()
            .map { index, caption in
                index == window.count - 1
                    ? caption.text
                    : caption.text.trimmingCharacters(in: seamPunctuation)
            }
            .joined(separator: " ")
        guard let subject = subject(in: joined) else { return nil }
        // The anchor names the row carrying the declaration; the joined text is
        // the evidence, because the sentence really did span rows.
        let anchored = window.first { containsAnchor($0.text) } ?? newest
        return StatedPriority(
            subject: subject,
            statement: joined.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceRowID: anchored.id,
            statedAt: anchored.startTime)
    }
}

// MARK: - Scanning

private extension StatedPriorityDetector {
    static func subject(in text: String) -> String? {
        let tokens = tokenize(text)
        if let anchor = anchorRange(in: tokens),
           !isInterrogative(tokens, around: anchor),
           !isDemoted(tokens, anchor: anchor),
           !isHypothetical(tokens, before: anchor.lowerBound),
           let found = forwardSubject(tokens, anchor: anchor)
               ?? backwardSubject(tokens, anchor: anchor),
           let phrase = validated(found) {
            return phrase
        }
        guard let verb = precedenceVerbRange(in: tokens),
              !isInterrogative(tokens, around: verb),
              !isDemoted(tokens, anchor: verb),
              !isHypothetical(tokens, before: verb.lowerBound),
              let found = backwardSubject(tokens, anchor: verb, requiresCopula: false),
              let phrase = validated(found)
        else { return nil }
        return phrase
    }

    /// Asking what the priority is states nothing — but only the clause holding
    /// the anchor decides that.
    ///
    /// This used to defer to `QuestionHeuristic.looksLikeQuestion`, which
    /// documents that it errs on the side of passing because a classifier prunes
    /// after it. Used here as a suppressor that bias inverts into false
    /// negatives: it treats a `?` anywhere in a multi-sentence caption as a
    /// question, and its interrogative list carries `por`, so "Por ahora la
    /// prioridad es X" was silently dropped.
    static func isInterrogative(_ tokens: [Token], around anchor: Range<Int>) -> Bool {
        let clause = clauseRange(in: tokens, containing: anchor)
        if tokens[clause].contains(where: \.opensQuestion) { return true }
        guard let first = clause.first else { return false }
        // Unfolded on purpose: in Spanish the accent is what separates an
        // interrogative from its unaccented everyday twin.
        return PriorityVocabulary.clauseInitialInterrogatives
            .contains(tokens[first].lowered)
    }

    /// The run of tokens between the clause breaks surrounding the anchor.
    static func clauseRange(in tokens: [Token], containing anchor: Range<Int>) -> Range<Int> {
        var start = anchor.lowerBound
        while start > 0, !tokens[start - 1].closesClause { start -= 1 }
        var end = anchor.upperBound - 1
        while end + 1 < tokens.count, !tokens[end].closesClause { end += 1 }
        return start..<(end + 1)
    }

    /// Earliest anchor, longest match at that position.
    static func anchorRange(in tokens: [Token]) -> Range<Int>? {
        matchRange(of: PriorityVocabulary.anchors, in: tokens)
    }

    static func precedenceVerbRange(in tokens: [Token]) -> Range<Int>? {
        matchRange(of: PriorityVocabulary.precedenceVerbPhrases, in: tokens)
    }

    static func matchRange(of phrases: [[String]], in tokens: [Token]) -> Range<Int>? {
        let ordered = phrases.sorted { $0.count > $1.count }
        for start in tokens.indices {
            for phrase in ordered where start + phrase.count <= tokens.count {
                let slice = tokens[start..<(start + phrase.count)].map(\.folded)
                if slice == phrase { return start..<(start + phrase.count) }
            }
        }
        return nil
    }

    static func containsAnchor(_ text: String) -> Bool {
        anchorRange(in: tokenize(text)) != nil
    }

    /// "The dashboard is a low priority" and "una prioridad baja" name what does
    /// NOT take precedence; reading either as a priority inverts the speaker.
    ///
    /// The scan follows the adjective run on both sides of the anchor — English
    /// pre-modifies, Spanish post-modifies — and stops at the clause boundary or
    /// at a copula, which is where the modifiers end. A fixed step count was
    /// wrong in both directions: two intensifiers ("una prioridad realmente muy
    /// baja") pushed the qualifier out of reach, and testing a token before
    /// checking its clause break let the previous sentence's "low" suppress a
    /// perfectly good declaration.
    static func isDemoted(_ tokens: [Token], anchor: Range<Int>) -> Bool {
        var index = anchor.lowerBound
        while index > 0 {
            index -= 1
            if tokens[index].closesClause { break }
            if PriorityVocabulary.copulas.contains(tokens[index].folded) { break }
            if PriorityVocabulary.demoting.contains(tokens[index].folded) { return true }
        }
        index = anchor.upperBound - 1
        while index + 1 < tokens.count {
            if tokens[index].closesClause { break }
            index += 1
            if PriorityVocabulary.copulas.contains(tokens[index].folded) { break }
            if PriorityVocabulary.demoting.contains(tokens[index].folded) { return true }
        }
        return false
    }
}

// MARK: - Directions

private extension StatedPriorityDetector {
    /// "<anchor> [right now] is <SUBJECT>"
    static func forwardSubject(_ tokens: [Token], anchor: Range<Int>) -> [Token]? {
        let anchorEnd = anchor.upperBound - 1
        var copula: Int?
        var index = anchorEnd
        while index + 1 < tokens.count, index - anchorEnd < maximumAnchorGap {
            if tokens[index].closesClause { return nil }
            index += 1
            if PriorityVocabulary.negations.contains(tokens[index].folded) { return nil }
            if PriorityVocabulary.copulas.contains(tokens[index].folded) {
                copula = index
                break
            }
        }
        guard let copula, copula + 1 < tokens.count else { return nil }
        guard !PriorityVocabulary.negations.contains(tokens[copula + 1].folded)
        else { return nil }
        return walkForward(tokens, from: copula + 1)
    }

    static func walkForward(_ tokens: [Token], from start: Int) -> [Token]? {
        var subject: [Token] = []
        var cursor = start
        while cursor < tokens.count {
            let token = tokens[cursor]
            if PriorityVocabulary.conjunctions.contains(token.folded) { break }
            // Running past the cap means the clause never named a subject; a
            // truncated one would read as a priority nobody stated.
            if PriorityVocabulary.negations.contains(token.folded) { return nil }
            if subject.count == maximumSubjectWords { return nil }
            subject.append(token)
            if token.closesClause {
                // "The priority is the dashboard, not the billing migration."
                // The clause break ends the subject before the correction is
                // ever seen, so reporting it would name the thing the speaker
                // just moved away from. Which of the two is meant is not
                // decidable here, so neither is claimed.
                let next = cursor + 1
                if next < tokens.count,
                   PriorityVocabulary.negations.contains(tokens[next].folded) {
                    return nil
                }
                break
            }
            cursor += 1
        }
        return subject.isEmpty ? nil : subject
    }

    /// "<SUBJECT> is [the top] <anchor>", or "<SUBJECT> <precedence verb>" when
    /// no copula is required.
    static func backwardSubject(
        _ tokens: [Token],
        anchor: Range<Int>,
        requiresCopula: Bool = true
    ) -> [Token]? {
        var start = anchor.lowerBound
        if requiresCopula {
            guard let copula = copulaBefore(tokens, anchor: anchor.lowerBound),
                  copula > 0
            else { return nil }
            start = copula
        }
        guard start > 0 else { return nil }
        var subject: [Token] = []
        var cursor = start - 1
        while cursor >= 0 {
            let token = tokens[cursor]
            if PriorityVocabulary.conjunctions.contains(token.folded) { break }
            // "The dashboard does not come first" names what does NOT take
            // precedence. The copular path catches this in `copulaBefore`; the
            // precedence-verb path has no such walk, so the subject itself is
            // where both are checked.
            if PriorityVocabulary.negations.contains(token.folded) { return nil }
            if subject.count == maximumSubjectWords { return nil }
            subject.insert(token, at: 0)
            // The clause flag sits on the token the punctuation follows, so a
            // break before the subject stops the walk here.
            if cursor > 0, tokens[cursor - 1].closesClause { break }
            cursor -= 1
        }
        return subject.isEmpty ? nil : subject
    }

    static func copulaBefore(_ tokens: [Token], anchor: Int) -> Int? {
        var index = anchor
        while index > 0, anchor - index < maximumAnchorGap {
            index -= 1
            if PriorityVocabulary.negations.contains(tokens[index].folded) { return nil }
            if tokens[index].closesClause { return nil }
            if PriorityVocabulary.copulas.contains(tokens[index].folded) { return index }
        }
        return nil
    }

    /// A conditional or modal anywhere in the clause leading to the anchor.
    static func isHypothetical(_ tokens: [Token], before anchor: Int) -> Bool {
        var index = anchor
        while index > 0 {
            index -= 1
            if PriorityVocabulary.conditionals.contains(tokens[index].lowered) { return true }
            if tokens[index].closesClause { return false }
        }
        return false
    }

    static func validated(_ subject: [Token]) -> String? {
        let phrase = subject.map(\.text).joined(separator: " ")
        guard phrase.count >= 2, phrase.count <= maximumSubjectCharacters
        else { return nil }
        // "so what is the priority" is a question the recognizer dropped the
        // mark from; its subject would be the question word itself.
        guard !subject.contains(where: {
            PriorityVocabulary.clauseInitialInterrogatives.contains($0.lowered)
        }) else { return nil }
        // At least one content word: "the priority is that" names nothing.
        guard subject.contains(where: {
            $0.folded.count >= 3 && !PriorityVocabulary.fillers.contains($0.folded)
        }) else { return nil }
        return phrase
    }

    /// Whether this caption's anchor already sits next to its copula, in
    /// either direction — that is a whole clause, not a fragment.
    static func hasCompleteClause(_ text: String) -> Bool {
        let tokens = tokenize(text)
        guard let anchor = anchorRange(in: tokens) else { return false }
        if copulaBefore(tokens, anchor: anchor.lowerBound) != nil { return true }
        let anchorEnd = anchor.upperBound - 1
        var index = anchorEnd
        while index + 1 < tokens.count, index - anchorEnd < maximumAnchorGap {
            if tokens[index].closesClause { return false }
            index += 1
            if PriorityVocabulary.copulas.contains(tokens[index].folded) { return true }
        }
        return false
    }

    static let seamPunctuation = CharacterSet(charactersIn: ".,;:\u{2026}\u{2014}\u{2013} ")

    /// The newest caption plus the predecessors it may legitimately join.
    static func joinableTail(of captions: [PriorityScanCaption]) -> [PriorityScanCaption] {
        guard let newest = captions.last else { return [] }
        var window: [PriorityScanCaption] = [newest]
        var index = captions.count - 1
        while index > 0, window.count < maximumJoinedCaptions {
            index -= 1
            let candidate = captions[index]
            guard candidate.channel == newest.channel,
                  candidate.speaker == newest.speaker,
                  newest.startTime - candidate.startTime <= maximumJoinSeconds
            else { break }
            window.insert(candidate, at: 0)
        }
        return window
    }
}

// MARK: - Tokens

private extension StatedPriorityDetector {
    struct Token {
        let text: String
        /// Lowercased only. The conditional list reads this, because Spanish
        /// "si" (if) and "si" with an accent (yes) are different words and
        /// folding them would abstain on a plain agreement.
        let lowered: String
        /// Lowercased and diacritic-folded. Every other vocabulary reads this,
        /// so one spelling covers both and a recognizer that drops an accent
        /// is read the same as one that keeps it.
        let folded: String
        /// True when clause punctuation follows this token.
        let closesClause: Bool
        /// True when a question mark sits against this token on either side.
        /// Inverted Spanish marks open the clause, plain ones close it, so both
        /// neighbours are tagged and the clause scan reads whichever it meets.
        let opensQuestion: Bool
    }

    static let clauseBreakers: Set<Character> = [
        ",", ".", ";", ":", "?", "!", "\u{2014}", "\u{2013}", "\u{2026}",
        // Inverted marks open a Spanish clause, so they close the one before.
        // Escaped so the English-prose ratchet reads punctuation, not prose.
        "\u{00BF}", "\u{00A1}"
    ]

    static let questionMarks: Set<Character> = ["?", "\u{00BF}"]

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var carriesQuestion = false
        func flush() {
            guard !current.isEmpty else { return }
            let lowered = current.lowercased()
            tokens.append(Token(
                text: current,
                lowered: lowered,
                folded: lowered.folding(
                    options: [.diacriticInsensitive], locale: nil),
                closesClause: false,
                opensQuestion: carriesQuestion))
            current = ""
            carriesQuestion = false
        }
        for character in text {
            if character.isLetter || character.isNumber
                || character == "-" || character == "'" || character == "\u{2019}" {
                current.append(character)
                continue
            }
            flush()
            guard clauseBreakers.contains(character) else { continue }
            let question = questionMarks.contains(character)
            // Only the INVERTED mark opens the clause that follows it. A
            // closing "?" ends its own clause, and tagging what came after it
            // made "Any other questions? OK the priority is X" look like a
            // question in its second clause.
            carriesQuestion = character == "\u{00BF}"
            guard let last = tokens.popLast() else { continue }
            tokens.append(Token(
                text: last.text,
                lowered: last.lowered,
                folded: last.folded,
                closesClause: true,
                opensQuestion: last.opensQuestion || question))
        }
        flush()
        return tokens
    }
}
