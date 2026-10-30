import Foundation
import NaturalLanguage

public enum StatedPriorityDecision: String, Equatable, Sendable {
    case priority
    case demotion
    case question
    case abstain
}

/// `classifiedNeutral` is a recognized absence of priority speech; the other
/// reasons are refusals, so they never earn credit as a neutral reading.
public enum StatedPriorityAbstention: String, Equatable, Sendable {
    case classifiedNeutral = "classified-neutral"
    case lowConfidence = "low-confidence"
    case missingContext = "missing-context"
    /// The tagger has no lexical-class or lemma assets for the captions' language.
    case runtimeUnavailable = "runtime-unavailable"
}

public struct StatedPrioritySpan: Hashable, Sendable {
    public let captionID: String
    public let quote: String

    public init(captionID: String, quote: String) {
        self.captionID = captionID
        self.quote = quote
    }
}

public struct StatedPriorityCaption: Equatable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public struct StatedPriorityFocus: Equatable, Sendable {
    public let captionID: String
    public let sentence: String
    public let mention: String?

    public init(captionID: String, sentence: String, mention: String?) {
        self.captionID = captionID
        self.sentence = sentence
        self.mention = mention
    }
}

public struct StatedPriorityReading: Equatable, Sendable {
    public let decision: StatedPriorityDecision
    public let abstention: StatedPriorityAbstention?
    public let target: StatedPrioritySpan?
    /// Whole sentences quoted exactly from their captions, the focal one included.
    public let evidence: [StatedPrioritySpan]

    static func abstain(_ reason: StatedPriorityAbstention) -> Self {
        Self(decision: .abstain, abstention: reason, target: nil, evidence: [])
    }

    static func claim(
        _ decision: StatedPriorityDecision, target: StatedPrioritySpan?, evidence: [StatedPrioritySpan]
    ) -> Self {
        Self(decision: decision, abstention: nil, target: target, evidence: evidence)
    }
}

/// Research-only linguistic baseline: reads whether a focal sentence declares,
/// demotes, or asks about a priority, using `NLTokenizer` sentences and
/// `NLTagger` lexical classes and lemmas. It is not wired into the app and
/// never writes objectives or summaries.
public struct StatedPriorityClassifier: Sendable {
    public static let arm = "linguistic-baseline-v1"

    private let isTaggerAvailable: @Sendable (NLLanguage) -> Bool

    public init() {
        self.init(isTaggerAvailable: { StatedPriorityText.isTaggerAvailable($0) })
    }

    init(isTaggerAvailable: @escaping @Sendable (NLLanguage) -> Bool) {
        self.isTaggerAvailable = isTaggerAvailable
    }

    public func classify(captions: [StatedPriorityCaption], focus: StatedPriorityFocus) -> StatedPriorityReading {
        let language = StatedPriorityText.language(of: captions)
        // Without tags every sentence reads as verbless, which would pass for neutral speech.
        guard isTaggerAvailable(language) else { return .abstain(.runtimeUnavailable) }
        guard let transcript = StatedPriorityTranscript(captions: captions, focus: focus, language: language) else {
            return .abstain(.missingContext)
        }
        if StatedPriorityGuards.addressesAssistant(transcript.focal) { return .abstain(.classifiedNeutral) }
        let mention = focus.mention.map { StatedPrioritySpan(captionID: focus.captionID, quote: $0) }
        let reading = transcript.focal.isQuestion
            ? questionReading(transcript, mention: mention)
            : statementReading(transcript, mention: mention)
        return grounded(reading, captions: captions, focal: transcript.focal.span)
    }

    // MARK: - Statements

    private func statementReading(
        _ transcript: StatedPriorityTranscript, mention: StatedPrioritySpan?
    ) -> StatedPriorityReading {
        let focal = transcript.focal
        guard case .claims(let claims) = StatedPriorityClauseParser(focal).parse() else {
            return .abstain(.classifiedNeutral)
        }
        let claim: StatedPriorityClaim
        switch choose(claims, in: focal, mention: mention?.quote) {
        case .abstain(let reason):
            // With no claim to protect, the whole sentence decides whether it asserts anything.
            let neutral = StatedPriorityGuards.nonAssertion(focal, excluding: nil) == .classifiedNeutral
            return .abstain(neutral ? .classifiedNeutral : reason)
        case .claim(let chosen): claim = chosen
        }
        if let reason = StatedPriorityGuards.nonAssertion(focal, excluding: claim.target) {
            return .abstain(reason)
        }
        var evidence = [focal.span]
        let target: StatedPrioritySpan
        if let mention {
            target = mention
        } else if let range = claim.target {
            target = StatedPrioritySpan(captionID: focal.captionID, quote: focal.quote(range))
        } else if let antecedent = antecedent(in: transcript) {
            target = antecedent.target
            evidence.insert(antecedent.sentence.span, at: 0)
        } else {
            return .abstain(.missingContext)
        }
        if let previous = transcript.previous, previous.isQuestion, !evidence.contains(previous.span),
           StatedPriorityClauseParser(previous).hasAnchor
            || Self.topic(of: previous).map({ Self.sameTarget($0, target.quote) }) == true {
            evidence.insert(previous.span, at: 0)
        }
        return superseded(claim.polarity, target: target, evidence: evidence, following: transcript.following)
    }

    private enum Choice {
        case claim(StatedPriorityClaim)
        case abstain(StatedPriorityAbstention)
    }

    private func choose(
        _ claims: [StatedPriorityClaim], in sentence: StatedPrioritySentence, mention: String?
    ) -> Choice {
        let live = claims.filter { !$0.retracted }
        guard let mention else {
            guard let first = live.first else { return .abstain(.classifiedNeutral) }
            return first.polarity == .ambiguous ? .abstain(.lowConfidence) : .claim(first)
        }
        let about = claims.filter { claim in
            claim.target.map { Self.sameTarget(sentence.quote($0), mention) } ?? false
        }
        let current = about.filter { !$0.retracted }
        if current.isEmpty, !about.isEmpty { return .abstain(.classifiedNeutral) }
        // A sentence whose only claim has no target of its own is about the mention it names.
        let candidates = current.isEmpty ? (claims.count == 1 && claims[0].target == nil ? claims : []) : current
        guard let first = candidates.first, Set(candidates.map(\.polarity)).count == 1,
              first.polarity != .ambiguous
        else { return .abstain(.lowConfidence) }
        return .claim(first)
    }

    /// A later claim about the same target replaces the focal one, and a
    /// retraction right after it withdraws it.
    private func superseded(
        _ polarity: StatedPriorityPolarity, target: StatedPrioritySpan, evidence: [StatedPrioritySpan],
        following: ArraySlice<StatedPrioritySentence>
    ) -> StatedPriorityReading {
        var polarity = polarity
        var evidence = evidence
        for (offset, later) in following.enumerated() where !later.isQuestion {
            guard !StatedPriorityGuards.addressesAssistant(later) else { continue }
            if offset == 0, later.contains(anyOf: StatedPriorityLexicon.retractions) {
                return .abstain(.classifiedNeutral)
            }
            guard StatedPriorityGuards.nonAssertion(later, excluding: nil) == nil,
                  case .claims(let claims) = StatedPriorityClauseParser(later).parse()
            else { continue }
            let corrects = later.contains(anyOf: StatedPriorityLexicon.correctionMarkers)
            for claim in claims where !claim.retracted {
                let same = claim.target.map { Self.sameTarget(later.quote($0), target.quote) } ?? (offset == 0)
                if same {
                    polarity = claim.polarity
                    evidence.append(later.span)
                    break
                }
                if corrects, claim.polarity == .priority, polarity == .priority { return .abstain(.classifiedNeutral) }
            }
        }
        switch polarity {
        case .priority: return .claim(.priority, target: target, evidence: evidence)
        case .demotion: return .claim(.demotion, target: target, evidence: evidence)
        case .ambiguous: return .abstain(.lowConfidence)
        }
    }

    /// The target a pronoun or a bare "La prioridad es baja." refers back to.
    private func antecedent(
        in transcript: StatedPriorityTranscript
    ) -> (target: StatedPrioritySpan, sentence: StatedPrioritySentence)? {
        guard let previous = transcript.previous else { return nil }
        if let topic = Self.topic(of: previous) {
            return (StatedPrioritySpan(captionID: previous.captionID, quote: topic), previous)
        }
        guard !previous.isQuestion,
              case .claims(let claims) = StatedPriorityClauseParser(previous).parse(),
              let range = claims.first(where: { !$0.retracted && $0.target != nil })?.target
        else { return nil }
        return (StatedPrioritySpan(captionID: previous.captionID, quote: previous.quote(range)), previous)
    }

    // MARK: - Questions

    private func questionReading(
        _ transcript: StatedPriorityTranscript, mention: StatedPrioritySpan?
    ) -> StatedPriorityReading {
        let focal = transcript.focal
        let asksPriority = StatedPriorityClauseParser(focal).hasAnchor
        let topic = Self.topic(of: focal)
        guard asksPriority || topic != nil else { return .abstain(.classifiedNeutral) }
        if let answer = transcript.following.first, !answer.isQuestion,
           !StatedPriorityGuards.addressesAssistant(answer),
           StatedPriorityGuards.nonAssertion(answer, excluding: nil) == nil,
           case .claims(let claims) = StatedPriorityClauseParser(answer).parse(),
           let claim = Self.answering(claims, in: answer, mention: mention?.quote) {
            let named = claim.target.map { StatedPrioritySpan(captionID: answer.captionID, quote: answer.quote($0)) }
            let target: StatedPrioritySpan? = if let mention {
                named.map { Self.sameTarget($0.quote, mention.quote) } ?? true ? mention : nil
            } else {
                named ?? topic.map { StatedPrioritySpan(captionID: focal.captionID, quote: $0) }
            }
            if let target {
                return superseded(
                    claim.polarity, target: target, evidence: [focal.span, answer.span],
                    following: transcript.following.dropFirst())
            }
        }
        // A bare "And X?" names a topic without asking about its priority.
        guard asksPriority else { return .abstain(.classifiedNeutral) }
        return .claim(.question, target: mention, evidence: [focal.span])
    }

    /// The answer's claim about the mention when it names one, else its first claim.
    private static func answering(
        _ claims: [StatedPriorityClaim], in answer: StatedPrioritySentence, mention: String?
    ) -> StatedPriorityClaim? {
        let live = claims.filter { !$0.retracted && $0.polarity != .ambiguous }
        let named = mention.flatMap { mention in
            live.first { claim in claim.target.map { sameTarget(answer.quote($0), mention) } ?? false }
        }
        return named ?? live.first
    }

    /// The noun phrase of "And X?", "What about X?", or their Spanish forms.
    static func topic(of sentence: StatedPrioritySentence) -> String? {
        guard sentence.isQuestion else { return nil }
        let content = sentence.tokens.indices.filter { !sentence.tokens[$0].isPunctuation }
        for lead in StatedPriorityLexicon.topicQuestionLeads where content.count > lead.count {
            guard lead.indices.allSatisfy({ sentence.tokens[content[$0]].word == lead[$0] }) else { continue }
            let rest = content[lead.count...]
            guard let first = rest.first, let last = rest.last,
                  !rest.contains(where: { sentence.tokens[$0].isVerb })
            else { return nil }
            return sentence.quote(first..<last + 1)
        }
        return nil
    }

    // MARK: - Targets and grounding

    /// Equal after folding and dropping a leading determiner, or one conjunct
    /// of a coordinated target ("the export and the dashboard").
    static func sameTarget(_ candidate: String, _ mention: String) -> Bool {
        let wanted = normalized(mention)
        let found = normalized(candidate)
        if found == wanted { return true }
        let conjuncts = found.replacingOccurrences(of: " and ", with: ",")
            .replacingOccurrences(of: " y ", with: ",")
            .split(separator: ",")
            .map { normalized(String($0)) }
        return conjuncts.count > 1 && conjuncts.contains(wanted)
    }

    private static func normalized(_ text: String) -> String {
        let determiners: Set<String> = [
            "the", "a", "an", "our", "el", "la", "los", "las", "un", "una", "nuestro", "nuestra"
        ]
        var words = StatedPriorityText.fold(text)
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        if let first = words.first, determiners.contains(first) { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// Every claim must quote whole sentences that occur once in their caption,
    /// include the focal sentence, and carry a target inside that evidence.
    private func grounded(
        _ reading: StatedPriorityReading, captions: [StatedPriorityCaption], focal: StatedPrioritySpan
    ) -> StatedPriorityReading {
        guard reading.decision != .abstain else { return reading }
        let texts = Dictionary(captions.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        var evidence: [StatedPrioritySpan] = []
        for span in reading.evidence where !evidence.contains(span) {
            if texts[span.captionID].map({ $0.components(separatedBy: span.quote).count == 2 }) == true {
                evidence.append(span)
            }
        }
        guard evidence.contains(focal) else { return .abstain(.missingContext) }
        if let target = reading.target,
           !evidence.contains(where: { $0.captionID == target.captionID && $0.quote.contains(target.quote) }) {
            return .abstain(.missingContext)
        }
        return .claim(reading.decision, target: reading.target, evidence: evidence)
    }
}
