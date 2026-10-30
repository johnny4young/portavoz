import Foundation

enum StatedPriorityPolarity: Equatable {
    case priority
    case demotion
    /// Two demoting signals, such as a negated low qualifier, cancel into no reading.
    case ambiguous
}

struct StatedPriorityClaim {
    let polarity: StatedPriorityPolarity
    /// Token range inside the sentence; `nil` when the target is a pronoun or
    /// elided and must come from an antecedent.
    let target: Range<Int>?
    var retracted = false
}

enum StatedPriorityParse {
    case noAnchor
    /// The priority vocabulary appears, but in no declaring construction.
    case topic
    case claims([StatedPriorityClaim])
}

private struct StatedPriorityAnchor {
    enum Kind { case noun, first, leastImportant, prioritize, deprioritize, hold }
    let kind: Kind
    let index: Int
    let end: Int
}

/// Reads the claims one sentence makes about a priority. Scope comes from
/// structure, never a token window: a clause ends at a semicolon, a subject
/// ends at its verb, and a qualifier counts only when it is not tagged a verb.
struct StatedPriorityClauseParser {
    typealias Lexicon = StatedPriorityLexicon
    let sentence: StatedPrioritySentence
    private var tokens: [StatedPriorityToken] { sentence.tokens }

    init(_ sentence: StatedPrioritySentence) { self.sentence = sentence }

    var hasAnchor: Bool { !anchors(in: tokens.indices).isEmpty }

    func parse() -> StatedPriorityParse {
        var anchored = false
        var result: [StatedPriorityClaim] = []
        for clause in clauses() {
            let anchors = anchors(in: clause)
            anchored = anchored || !anchors.isEmpty
            for anchor in anchors {
                let found = claims(for: anchor, in: clause)
                guard !found.isEmpty else { continue }
                let antecedent = result.last { $0.target != nil && !$0.retracted }?.target
                result += found.map { claim in
                    guard claim.target == nil, let antecedent else { return claim }
                    return StatedPriorityClaim(polarity: claim.polarity, target: antecedent)
                }
                break
            }
        }
        if !result.isEmpty { return .claims(result) }
        return anchored ? .topic : .noAnchor
    }

    private func clauses() -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        for index in tokens.indices where tokens[index].word == ";" {
            if start < index { result.append(start..<index) }
            start = index + 1
        }
        if start < tokens.count { result.append(start..<tokens.count) }
        return result
    }

    private func anchors(in clause: Range<Int>) -> [StatedPriorityAnchor] {
        var result: [StatedPriorityAnchor] = []
        for index in clause {
            if let kind = anchorKind(at: index, in: clause) {
                result.append(StatedPriorityAnchor(kind: kind, index: index, end: index + 1))
            }
        }
        for phrase in Lexicon.holdPhrases {
            for start in sentence.occurrences(of: phrase, in: clause) {
                result.append(StatedPriorityAnchor(kind: .hold, index: start, end: start + phrase.count))
            }
        }
        return result.sorted { $0.index < $1.index }
    }

    private func anchorKind(at index: Int, in clause: Range<Int>) -> StatedPriorityAnchor.Kind? {
        let token = tokens[index]
        if token.matches(Lexicon.prioritizingVerbs) { return .prioritize }
        if token.matches(Lexicon.deprioritizingVerbs) { return .deprioritize }
        guard !token.isVerb else { return nil }
        if token.matches(Lexicon.anchorNouns) { return isCompoundModifier(index, in: clause) ? nil : .noun }
        if token.matches(Lexicon.firstWords) { return .first }
        guard token.matches(Lexicon.importantWords), index > clause.lowerBound else { return nil }
        let previous = tokens[index - 1]
        if previous.matches(Lexicon.mostWords) { return .noun }
        return previous.matches(Lexicon.leastWords) ? .leastImportant : nil
    }

    /// "priority list" and "lista de prioridades" name a thing, not a priority.
    private func isCompoundModifier(_ index: Int, in clause: Range<Int>) -> Bool {
        if index + 1 < clause.upperBound, tokens[index + 1].isNoun,
           !tokens[index + 1].matches(Lexicon.temporalWords) {
            return true
        }
        guard index - 2 >= clause.lowerBound, ["of", "de"].contains(tokens[index - 1].word) else { return false }
        return tokens[index - 2].isNoun
    }

    private func claims(for anchor: StatedPriorityAnchor, in clause: Range<Int>) -> [StatedPriorityClaim] {
        switch anchor.kind {
        case .noun, .leastImportant: nounClaims(anchor, in: clause)
        case .first:
            if let verb = head(before: anchor.index, in: clause), tokens[verb].isVerb,
               tokens[verb].matches(Lexicon.firstVerbs) {
                subjectClaims(anchor, verb: verb, in: clause)
            } else {
                []
            }
        case .prioritize: objectClaims(anchor, polarity: .priority, in: clause)
        case .deprioritize: objectClaims(anchor, polarity: .demotion, in: clause)
        case .hold: holdClaims(anchor, in: clause)
        }
    }

    private func nounClaims(_ anchor: StatedPriorityAnchor, in clause: Range<Int>) -> [StatedPriorityClaim] {
        // "lower the priority" puts the determiner after the word, "a lower priority" before
        // it, which holds even where the tagger calls a sentence-medial verb an adverb.
        let determiner = anchor.index - 1
        if determiner - 1 >= clause.lowerBound, tokens[determiner].isDeterminer,
           tokens[determiner - 1].matches(Lexicon.demotingVerbs) {
            return demotingVerbClaims(anchor, verb: determiner - 1, in: clause)
        }
        if let verb = head(before: anchor.index, in: clause), tokens[verb].isVerb {
            if tokens[verb].matches(Lexicon.possessiveVerbs) {
                let bare = (verb + 1..<anchor.index).allSatisfy {
                    tokens[$0].isNegation || tokens[$0].isQualifier || tokens[$0].isPromotingQualifier
                }
                return bare ? subjectClaims(anchor, verb: verb, in: clause) : []
            }
            if tokens[verb].matches(Lexicon.subjectVerbs) { return subjectClaims(anchor, verb: verb, in: clause) }
            if tokens[verb].matches(Lexicon.demotingVerbs) { return demotingVerbClaims(anchor, verb: verb, in: clause) }
            return []
        }
        // A coordinator starts another clause: "Priorities shift and the export is late."
        let end = (anchor.end..<clause.upperBound).first { tokens[$0].matches(Lexicon.coordinators) }
        let link = (anchor.end..<(end ?? clause.upperBound)).first {
            (tokens[$0].isVerb && tokens[$0].matches(Lexicon.linkingVerbs)) || tokens[$0].word == ":"
        }
        guard let link else { return [] }
        return predicateClaims(anchor, link: link, in: clause)
    }

    /// The first token before `index` that is not a determiner, modifier,
    /// negation, or the preposition of "is of high priority".
    private func head(before index: Int, in clause: Range<Int>) -> Int? {
        var cursor = index - 1
        while cursor >= clause.lowerBound {
            let token = tokens[cursor]
            let skippable = token.isDeterminer || token.isModifier || token.isNegation
                || token.tag == .particle || token.tag == .number || ["of", "de", "en"].contains(token.word)
            guard skippable else { return cursor }
            cursor -= 1
        }
        return nil
    }

    // MARK: - X is the priority

    private func subjectClaims(
        _ anchor: StatedPriorityAnchor, verb: Int, in clause: Range<Int>
    ) -> [StatedPriorityClaim] {
        var subjectEnd = verb
        while subjectEnd > clause.lowerBound, isSubjectTail(subjectEnd - 1) { subjectEnd -= 1 }
        var attachedEnd = anchor.end
        while attachedEnd < clause.upperBound, tokens[attachedEnd].isModifier { attachedEnd += 1 }
        let link = Array(subjectEnd..<anchor.index) + Array(anchor.end..<attachedEnd)
        let polarity = polarity(of: link, anchor: anchor)
        let claims: [StatedPriorityClaim] = subjectTargets(clause.lowerBound..<subjectEnd).compactMap { subject in
            guard let range = subject.range else {
                return StatedPriorityClaim(polarity: polarity, target: nil, retracted: subject.retracted)
            }
            // "We", "nosotros": a possessor or the speakers, never the thing ranked.
            if range.count == 1, tokens[range.lowerBound].matches(Lexicon.personalPronouns) { return nil }
            // "Nothing is the priority", "Neither X nor Y is…": the subject negates itself.
            let negated = tokens[range.lowerBound].isNegation
            return StatedPriorityClaim(
                polarity: negated ? .ambiguous : polarity, target: range, retracted: subject.retracted)
        }
        guard !claims.isEmpty else { return [] }
        return claims + tailContrast(from: attachedEnd, in: clause, primary: polarity)
    }

    private func isSubjectTail(_ index: Int) -> Bool {
        let token = tokens[index]
        if token.matches(Lexicon.negativeSubjects) { return false }
        return token.isNegation || token.tag == .adverb || token.word == "de" || isCeasing(index)
            || (token.isVerb && token.matches(Lexicon.auxiliaries))
    }

    /// "deja de ser", "stops being". The frame, not the verb's lexical class,
    /// decides: the tagger reads a sentence-medial "deja" as an adjective.
    private func isCeasing(_ index: Int) -> Bool {
        guard index + 1 < tokens.count else { return false }
        let token = tokens[index]
        let next = tokens[index + 1]
        if token.lemma == "dejar" || token.word.hasPrefix("dej") { return next.word == "de" }
        return token.matches(Lexicon.ceasingVerbs) && next.lemma == "be"
    }

    /// The subject's last comma-separated piece, so a recognizer comma or a
    /// fronted adjunct does not swallow it, and "X, eso es…" resolves to X.
    private func subjectTargets(_ range: Range<Int>) -> [(range: Range<Int>?, retracted: Bool)] {
        var pieces = split(range, where: { tokens[$0].word == "," })
        var retracted: [Range<Int>] = []
        if let marker = pieces.lastIndex(where: { correction(startingAt: $0.lowerBound, in: $0) != nil }) {
            retracted = pieces[..<marker].compactMap(trimmedTarget)
            let piece = pieces[marker]
            let markerEnd = correction(startingAt: piece.lowerBound, in: piece) ?? piece.lowerBound
            pieces = [markerEnd..<pieces[marker].upperBound] + pieces[(marker + 1)...]
        }
        let targets = pieces.compactMap(trimmedTarget)
        let old = retracted.map { (range: Optional($0), retracted: true) }
        guard let last = targets.last else { return old + [(nil, false)] }
        guard isPronoun(last) else { return old + [(last, false)] }
        return old + [(targets.count >= 2 ? targets[targets.count - 2] : nil, false)]
    }

    /// "X is not the priority, Y is" and "X is the priority, not Y".
    private func tailContrast(
        from start: Int, in clause: Range<Int>, primary: StatedPriorityPolarity
    ) -> [StatedPriorityClaim] {
        var cursor = start
        guard cursor < clause.upperBound,
              tokens[cursor].word == "," || tokens[cursor].matches(Lexicon.contrastWords)
        else { return [] }
        while cursor < clause.upperBound, tokens[cursor].word == "," || tokens[cursor].matches(Lexicon.contrastWords) {
            cursor += 1
        }
        if primary == .priority, cursor < clause.upperBound, tokens[cursor].isNegation {
            guard let target = trimmedTarget(cursor + 1..<clause.upperBound) else { return [] }
            return [StatedPriorityClaim(polarity: .demotion, target: target)]
        }
        // "…, Y is not either" repeats the demotion rather than contrasting it.
        guard primary == .demotion, !(cursor..<clause.upperBound).contains(where: { tokens[$0].isNegation }),
              let close = (cursor..<clause.upperBound).first(where: { isElidedPredicate(tokens[$0]) }),
              let target = trimmedTarget(cursor..<close)
        else { return [] }
        return [StatedPriorityClaim(polarity: .priority, target: target)]
    }

    private func isElidedPredicate(_ token: StatedPriorityToken) -> Bool {
        token.text.lowercased() == "s\u{ED}" || ["does", "do", "too", "tambien"].contains(token.word)
            || (token.isVerb && token.matches(Lexicon.linkingVerbs))
    }

    // MARK: - The priority is X

    private func predicateClaims(
        _ anchor: StatedPriorityAnchor, link: Int, in clause: Range<Int>
    ) -> [StatedPriorityClaim] {
        var before: [Int] = []
        var cursor = anchor.index - 1
        while cursor >= clause.lowerBound, tokens[cursor].isDeterminer || tokens[cursor].isModifier {
            before.append(cursor)
            cursor -= 1
        }
        let ofIndex = (anchor.end..<link).first { ["of", "de", "del"].contains(tokens[$0].word) }
        let ofTarget = ofIndex.flatMap { trimmedTarget($0 + 1..<link) }
        var linkIndices = before + Array(anchor.end..<(ofIndex ?? link))
        var start = link + 1
        while start < clause.upperBound, isComplementLead(tokens[start]) {
            if tokens[start].isNegation { linkIndices.append(start) }
            start += 1
        }
        let polarity = polarity(of: linkIndices, anchor: anchor)
        let complement = start..<clause.upperBound
        if let qualified = qualifierPolarity(complement) {
            let combined: StatedPriorityPolarity = switch (polarity, qualified) {
            case (.priority, _): qualified
            case (.demotion, .priority): .demotion
            default: .ambiguous
            }
            return [StatedPriorityClaim(polarity: combined, target: ofTarget)]
        }
        return complementClaims(complement, polarity: polarity)
    }

    private func isComplementLead(_ token: StatedPriorityToken) -> Bool {
        token.isNegation || token.isPunctuation || (token.tag == .particle && token.word == "to")
            || (token.tag == .adverb && !token.isQualifier && !token.isPromotingQualifier)
            || (token.tag == .conjunction && token.word == "que")
    }

    /// `.demotion` for "is low", `.priority` for "is high", `nil` when the
    /// complement names something.
    private func qualifierPolarity(_ range: Range<Int>) -> StatedPriorityPolarity? {
        let content = range.filter {
            let token = tokens[$0]
            return !token.isPunctuation && !token.isDeterminer && !token.matches(Lexicon.intensifiers)
        }
        guard !content.isEmpty else { return nil }
        if content.allSatisfy({ tokens[$0].isQualifier }) { return .demotion }
        if content.allSatisfy({ tokens[$0].isPromotingQualifier }) { return .priority }
        return nil
    }

    private func complementClaims(_ range: Range<Int>, polarity: StatedPriorityPolarity) -> [StatedPriorityClaim] {
        var claims: [StatedPriorityClaim] = []
        var current = range
        if let marker = range.first(where: { correction(startingAt: $0, in: range) != nil }),
           var markerEnd = correction(startingAt: marker, in: range) {
            if let old = trimmedTarget(range.lowerBound..<marker) {
                claims.append(StatedPriorityClaim(polarity: polarity, target: old, retracted: true))
            }
            // "sorry, I mean" stacks two markers.
            while let next = correction(startingAt: markerEnd, in: range) { markerEnd = next }
            current = markerEnd..<range.upperBound
        }
        let contrast = current.first {
            tokens[$0].matches(Lexicon.contrastWords)
                || (tokens[$0].word == "," && $0 + 1 < current.upperBound && tokens[$0 + 1].isNegation)
        }
        guard let contrast else {
            return claims + [StatedPriorityClaim(polarity: polarity, target: targetOrAntecedent(current))]
        }
        let first = targetOrAntecedent(current.lowerBound..<contrast)
        claims.append(StatedPriorityClaim(polarity: polarity, target: first))
        let negated = tokens[contrast].word == ","
        var second = contrast + 1
        while second < current.upperBound, tokens[second].isNegation || tokens[second].word == "," { second += 1 }
        if let target = trimmedTarget(second..<current.upperBound) {
            if negated, polarity == .priority {
                claims.append(StatedPriorityClaim(polarity: .demotion, target: target))
            }
            if !negated, polarity == .demotion {
                claims.append(StatedPriorityClaim(polarity: .priority, target: target))
            }
        }
        return claims
    }

    // MARK: - Verbs that act on a priority

    private func demotingVerbClaims(
        _ anchor: StatedPriorityAnchor, verb: Int, in clause: Range<Int>
    ) -> [StatedPriorityClaim] {
        let negated = (clause.lowerBound..<verb).contains { tokens[$0].isNegation }
        let preposition = (anchor.end..<clause.upperBound).first {
            ["of", "on", "for", "de", "del", "a"].contains(tokens[$0].word)
        }
        let target = preposition.flatMap { trimmedTarget($0 + 1..<clause.upperBound) }
        return [StatedPriorityClaim(polarity: negated ? .ambiguous : .demotion, target: target)]
    }

    private func objectClaims(
        _ anchor: StatedPriorityAnchor, polarity: StatedPriorityPolarity, in clause: Range<Int>
    ) -> [StatedPriorityClaim] {
        let negated = (clause.lowerBound..<anchor.index).contains { tokens[$0].isNegation }
        let resolved: StatedPriorityPolarity = !negated ? polarity : (polarity == .priority ? .demotion : .ambiguous)
        return [StatedPriorityClaim(polarity: resolved, target: targetOrAntecedent(anchor.end..<clause.upperBound))]
    }

    private func holdClaims(_ anchor: StatedPriorityAnchor, in clause: Range<Int>) -> [StatedPriorityClaim] {
        var verb = anchor.index - 1
        while verb >= clause.lowerBound, !isHoldVerb(tokens[verb]) {
            if tokens[verb].isPunctuation { return [] }
            verb -= 1
        }
        guard verb >= clause.lowerBound else { return [] }
        if (clause.lowerBound..<verb).contains(where: { tokens[$0].isNegation }) {
            return [StatedPriorityClaim(polarity: .ambiguous, target: nil)]
        }
        if tokens[verb].matches(Lexicon.holdPlacingVerbs) {
            return [StatedPriorityClaim(polarity: .demotion, target: targetOrAntecedent(verb + 1..<anchor.index))]
        }
        guard tokens[verb].matches(Lexicon.holdStateVerbs) else { return [] }
        var subjectEnd = verb
        while subjectEnd > clause.lowerBound, isSubjectTail(subjectEnd - 1) { subjectEnd -= 1 }
        return subjectTargets(clause.lowerBound..<subjectEnd).map {
            StatedPriorityClaim(polarity: .demotion, target: $0.range, retracted: $0.retracted)
        }
    }

    /// The tagger can call a conjugated "dejamos" a noun; its lemma still says dejar.
    private func isHoldVerb(_ token: StatedPriorityToken) -> Bool {
        token.isVerb || token.matches(Lexicon.holdPlacingVerbs)
    }

    // MARK: - Shared readings

    private func polarity(of indices: [Int], anchor: StatedPriorityAnchor) -> StatedPriorityPolarity {
        let signals = indices.filter {
            tokens[$0].isNegation || isCeasing($0) || (tokens[$0].isQualifier && !isTemporalModifier($0))
        }.count + (anchor.kind == .leastImportant ? 1 : 0)
        switch signals {
        case 0: return .priority
        case 1: return .demotion
        default: return .ambiguous
        }
    }

    /// "last" in "since last week" dates the claim rather than ranking it.
    private func isTemporalModifier(_ index: Int) -> Bool {
        index + 1 < tokens.count && tokens[index + 1].matches(Lexicon.temporalWords)
    }

    /// End index of a correction marker ("I mean", "mejor dicho") starting at `index`.
    func correction(startingAt index: Int, in range: Range<Int>) -> Int? {
        for marker in Lexicon.correctionMarkers where index + marker.count <= range.upperBound {
            if marker.indices.allSatisfy({ tokens[index + $0].word == marker[$0] }) {
                var end = index + marker.count
                while end < range.upperBound, tokens[end].isPunctuation { end += 1 }
                return end
            }
        }
        return nil
    }

    private func targetOrAntecedent(_ range: Range<Int>) -> Range<Int>? {
        guard let target = trimmedTarget(range), !isPronoun(target) else { return nil }
        return target
    }

    private func isPronoun(_ range: Range<Int>) -> Bool {
        range.count == 1 && Lexicon.pronouns.contains(tokens[range.lowerBound].word)
    }

    /// Trims punctuation, discourse markers, a comparison ("over Y"), and
    /// trailing temporal adjuncts ("this week", "por ahora").
    func trimmedTarget(_ range: Range<Int>) -> Range<Int>? {
        var lower = range.lowerBound
        var upper = range.upperBound
        if let cut = (lower..<upper).dropFirst().first(where: { tokens[$0].matches(Lexicon.comparisonWords) }) {
            upper = cut
        }
        while lower < upper, tokens[lower].isPunctuation || tokens[lower].matches(Lexicon.discourseMarkers)
            || (tokens[lower].tag == .particle && tokens[lower].word == "to") {
            lower += 1
        }
        upper = trimmedTemporal(lower..<upper)
        guard lower < upper, (lower..<upper).contains(where: { !tokens[$0].isDeterminer }) else { return nil }
        return lower..<upper
    }

    private func trimmedTemporal(_ range: Range<Int>) -> Int {
        var upper = range.upperBound
        while upper > range.lowerBound, tokens[upper - 1].isPunctuation { upper -= 1 }
        var end = upper
        while end > range.lowerBound, tokens[end - 1].matches(Lexicon.temporalWords) {
            end -= 1
            while end > range.lowerBound,
                  tokens[end - 1].matches(Lexicon.temporalModifiers) || tokens[end - 1].isPunctuation {
                end -= 1
            }
            upper = end
        }
        while upper > range.lowerBound, tokens[upper - 1].isPunctuation { upper -= 1 }
        return upper
    }

    private func split(_ range: Range<Int>, where isSeparator: (Int) -> Bool) -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var start = range.lowerBound
        for index in range where isSeparator(index) {
            pieces.append(start..<index)
            start = index + 1
        }
        pieces.append(start..<range.upperBound)
        return pieces
    }
}
