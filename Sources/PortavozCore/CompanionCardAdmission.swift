import Foundation

/// Result of admitting one generated Companion card into the current meeting.
///
/// A replacement preserves the "one question turn, one card" contract when a
/// still-growing live caption produces a more complete model result.
public enum CompanionCardAdmissionDecision: Equatable, Sendable {
    case append
    case replace(index: Int)
    case reject
}

/// Pure last-mile policy for repeated Companion output.
///
/// Model scheduling bounds work, not meaning: the silence endpointer can send
/// a growing row and the later row-close can send its completed form. Exact
/// string equality misses those near-identical questions and can leave two
/// contradictory answers on screen. Source lineage is authoritative; a short
/// time-bounded lexical fallback covers a caption split across adjacent rows.
public enum CompanionCardAdmission {
    private static let lexicalDuplicateWindow: TimeInterval = 12
    private static let minimumDistinctiveTokens = 4
    private static let stopWords: Set<String> = [
        // English
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "can",
        "could", "did", "do", "does", "for", "from", "how", "i", "if", "in",
        "is", "it", "of", "on", "or", "that", "the", "they", "this", "to",
        "uh", "um", "we", "what", "when", "where", "which", "who", "with",
        "would", "you",
        // Spanish
        "a", "al", "como", "con", "cual", "cuando", "de", "del", "donde",
        "el", "en", "es", "este", "la", "las", "lo", "los", "o", "para",
        "por", "que", "se", "si", "son", "un", "una", "y", "yo"
    ]
    private static let negations: Set<String> = [
        "cannot", "cant", "doesnt", "dont", "isnt", "never", "no", "not",
        "nothing", "sin", "ni", "nunca", "tampoco", "wont", "without"
    ]

    public static func decision(
        existing: [CompanionCard],
        candidate: CompanionCard
    ) -> CompanionCardAdmissionDecision {
        for (index, current) in existing.enumerated() {
            guard representsSameQuestion(current, candidate) else { continue }
            return shouldPrefer(candidate, over: current)
                ? .replace(index: index)
                : .reject
        }
        return .append
    }
}

private extension CompanionCardAdmission {
    static func representsSameQuestion(
        _ current: CompanionCard,
        _ candidate: CompanionCard
    ) -> Bool {
        if sharesQuestionLineage(current, candidate) {
            return true
        }

        let currentTokens = tokens(in: current.question)
        let candidateTokens = tokens(in: candidate.question)
        guard abs(current.askedAt - candidate.askedAt) <= lexicalDuplicateWindow else {
            return false
        }
        if currentTokens == candidateTokens {
            return !currentTokens.isEmpty
        }

        let currentSet = distinctiveTokens(currentTokens)
        let candidateSet = distinctiveTokens(candidateTokens)
        guard currentSet.count >= minimumDistinctiveTokens,
              candidateSet.count >= minimumDistinctiveTokens,
              hasMatchingNegationPolarity(currentTokens, candidateTokens)
        else {
            return false
        }

        let overlap = currentSet.intersection(candidateSet).count
        let containment = Double(overlap) / Double(min(currentSet.count, candidateSet.count))
        let union = currentSet.union(candidateSet).count
        let jaccard = union == 0 ? 0 : Double(overlap) / Double(union)
        return containment >= 0.9 && jaccard >= 0.75
    }

    static func sharesQuestionLineage(
        _ current: CompanionCard,
        _ candidate: CompanionCard
    ) -> Bool {
        guard let currentIDs = current.evidence?.questionSegmentIDs,
              let candidateIDs = candidate.evidence?.questionSegmentIDs,
              !currentIDs.isEmpty,
              !candidateIDs.isEmpty
        else {
            return false
        }
        return !Set(currentIDs).isDisjoint(with: candidateIDs)
    }

    static func shouldPrefer(
        _ candidate: CompanionCard,
        over current: CompanionCard
    ) -> Bool {
        let currentTokens = tokens(in: current.question)
        let candidateTokens = tokens(in: candidate.question)
        if candidateTokens.count != currentTokens.count {
            return candidateTokens.count > currentTokens.count
        }
        let currentSources = current.evidence?.questionSegmentIDs.count ?? 0
        let candidateSources = candidate.evidence?.questionSegmentIDs.count ?? 0
        if candidateSources != currentSources {
            return candidateSources > currentSources
        }
        if candidate.answer.isEmpty != current.answer.isEmpty {
            return !candidate.answer.isEmpty
        }
        if candidate.directed != current.directed {
            return candidate.directed
        }
        return false
    }

    static func tokens(in text: String) -> [String] {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    static func distinctiveTokens(_ tokens: [String]) -> Set<String> {
        Set(tokens.filter { token in
            token.count >= 2 && !stopWords.contains(token)
        })
    }

    static func hasMatchingNegationPolarity(
        _ lhs: [String],
        _ rhs: [String]
    ) -> Bool {
        let lhsIsNegated = !Set(lhs).isDisjoint(with: negations)
        let rhsIsNegated = !Set(rhs).isDisjoint(with: negations)
        return lhsIsNegated == rhsIsNegated
    }
}
