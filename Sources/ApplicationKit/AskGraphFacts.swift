import Foundation
import PortavozCore
import StorageKit

/// One caller-resolved graph fact request. Natural-language extraction and
/// cross-lane selection remain outside this exact retrieval boundary.
public enum AskGraphFactQuery: Equatable, Sendable {
    case commitmentBlockers(CommitmentBlockerQuery)
    case topicFirstDiscussion(TopicFirstDiscussionQuery)
    case personCommitments(PersonCommitmentsQuery)
    case decisionConflicts(DecisionConflictsQuery)
    case changeSince(ChangeSinceQuery)
}

/// Independent graph-fact retrieval for Ask. The result keeps typed facts and
/// abstention separate from transcript citations and generated prose.
public protocol AskGraphFactRetrieving: Sendable {
    func retrieve(
        _ query: AskGraphFactQuery
    ) async throws -> MeetingMemoryGraphQueryResult
}

/// Product adapter over the exact source-backed fact ports. Graph topology can
/// select candidates, but every returned result is hydrated by authoritative
/// storage through the existing use cases.
public struct LocalAskGraphFactRetrieval: AskGraphFactRetrieving {
    private let blockers: any CommitmentBlockerFactReading
    private let topics: any TopicFirstDiscussionReading
    private let commitments: any PersonCommitmentFactReading
    private let conflicts: any DecisionConflictsReading
    private let changes: any ChangeSinceReading

    public init(store: MeetingStore) {
        blockers = store
        topics = store
        commitments = store
        conflicts = store
        changes = store
    }

    public init(
        blockers: any CommitmentBlockerFactReading,
        topics: any TopicFirstDiscussionReading,
        commitments: any PersonCommitmentFactReading,
        conflicts: any DecisionConflictsReading,
        changes: any ChangeSinceReading
    ) {
        self.blockers = blockers
        self.topics = topics
        self.commitments = commitments
        self.conflicts = conflicts
        self.changes = changes
    }

    public func retrieve(
        _ query: AskGraphFactQuery
    ) async throws -> MeetingMemoryGraphQueryResult {
        switch query {
        case .commitmentBlockers(let query):
            return try await LoadCommitmentBlockers(repository: blockers)
                .execute(query)
        case .topicFirstDiscussion(let query):
            return try await LoadTopicFirstDiscussion(repository: topics)
                .execute(query)
        case .personCommitments(let query):
            return try await LoadPersonCommitments(repository: commitments)
                .execute(query)
        case .decisionConflicts(let query):
            return try await LoadDecisionConflicts(repository: conflicts)
                .execute(query)
        case .changeSince(let query):
            return try await LoadChangeSince(repository: changes)
                .execute(query)
        }
    }
}

/// A requested graph lane may return facts, abstain for a typed domain reason,
/// or be operationally unavailable. It never replaces transcript evidence.
public enum AskGraphFactLaneOutcome: Equatable, Sendable {
    case notRequested
    case result(MeetingMemoryGraphQueryResult)
    case unavailable
}

/// Final evidence from two independent lanes. Graph facts never enter
/// transcript ranking, and every fact keeps its own exact source segments.
public struct AskEvidenceBundle: Equatable, Sendable {
    public let transcriptCitations: [AskCitation]
    public let graphFacts: AskGraphFactLaneOutcome

    public init(
        transcriptCitations: [AskCitation],
        graphFacts: AskGraphFactLaneOutcome
    ) {
        self.transcriptCitations = transcriptCitations
        self.graphFacts = graphFacts
    }
}

/// One typed graph fact prepared for answer synthesis together with the exact
/// current transcript segments that authorize it. The fact is not flattened
/// into transcript rank or generated prose at this boundary.
public struct AskGraphFactSynthesisEvidence: Equatable, Sendable {
    public let fact: MeetingMemoryGraphFact
    public let sourceSegments: [AskCitation]

    public init?(fact: MeetingMemoryGraphFact) {
        let subject = fact.subjectText.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let object = fact.objectText.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard fact.occurredAt.timeIntervalSinceReferenceDate.isFinite,
              !subject.isEmpty,
              !object.isEmpty,
              !fact.evidence.isEmpty,
              fact.evidence.filter({
                  $0.segmentID == fact.primaryEvidenceSegmentID
              }).count == 1,
              Set(fact.evidence.map(\.segmentID)).count == fact.evidence.count,
              fact.evidence.allSatisfy(Self.isValid)
        else { return nil }
        self.fact = fact
        sourceSegments = fact.evidence.map { source in
            AskCitation(
                segmentID: source.segmentID,
                meetingID: source.meetingID,
                meetingTitle: source.meetingTitle,
                timestamp: source.startTime,
                transcriptRevision: source.transcriptRevision,
                text: source.text)
        }
    }

    private static func isValid(_ source: MeetingMemoryGraphEvidence) -> Bool {
        let title = source.meetingTitle.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let text = source.text.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let languageIsValid = source.language.map {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? true
        return source.meetingStartedAt.timeIntervalSinceReferenceDate.isFinite
            && source.transcriptRevision >= 0
            && source.startTime.isFinite
            && source.startTime >= 0
            && source.endTime.isFinite
            && source.endTime >= source.startTime
            && !title.isEmpty
            && !text.isEmpty
            && languageIsValid
    }
}

/// One admitted graph page. Pagination and omission disclosure travels with
/// the facts so a generator cannot turn a partial result into an "all" or
/// "none" claim.
public struct AskGraphFactSynthesisPage: Equatable, Sendable {
    public let facts: [AskGraphFactSynthesisEvidence]
    public let hasMore: Bool
    public let projectionGeneration: Int
    public let omittedStaleCount: Int
    public let omittedUnavailableCount: Int
    public let selectionOmittedCount: Int

    public init?(page: MeetingMemoryGraphFactPage) {
        guard !page.facts.isEmpty,
              page.projectionGeneration > 0,
              page.omittedStaleCount >= 0,
              page.omittedUnavailableCount >= 0,
              Set(page.facts.map(\.id)).count == page.facts.count
        else { return nil }

        let prepared = page.facts.compactMap(
            AskGraphFactSynthesisEvidence.init)
        guard prepared.count == page.facts.count,
              Self.hasConsistentSources(prepared)
        else { return nil }

        facts = prepared
        hasMore = page.hasMore
        projectionGeneration = page.projectionGeneration
        omittedStaleCount = page.omittedStaleCount
        omittedUnavailableCount = page.omittedUnavailableCount
        selectionOmittedCount = 0
    }

    private init(
        facts: [AskGraphFactSynthesisEvidence],
        hasMore: Bool,
        projectionGeneration: Int,
        omittedStaleCount: Int,
        omittedUnavailableCount: Int,
        selectionOmittedCount: Int
    ) {
        self.facts = facts
        self.hasMore = hasMore
        self.projectionGeneration = projectionGeneration
        self.omittedStaleCount = omittedStaleCount
        self.omittedUnavailableCount = omittedUnavailableCount
        self.selectionOmittedCount = selectionOmittedCount
    }

    /// The leading `count` facts of this already-validated page, in query
    /// order. Post-RRF selection only ever shortens a page, so every retained
    /// fact keeps provenance the full page already proved, and the dropped
    /// remainder is added to the selection omission count. Returns nil for a
    /// `count` outside `1...facts.count`: an empty page is never valid
    /// material, and a longer one cannot come from narrowing.
    func selectingPrefix(_ count: Int) -> AskGraphFactSynthesisPage? {
        guard count > 0, count <= facts.count else { return nil }
        return AskGraphFactSynthesisPage(
            facts: Array(facts.prefix(count)),
            hasMore: hasMore,
            projectionGeneration: projectionGeneration,
            omittedStaleCount: omittedStaleCount,
            omittedUnavailableCount: omittedUnavailableCount,
            selectionOmittedCount:
                selectionOmittedCount + (facts.count - count))
    }

    public var isComplete: Bool {
        !hasMore
            && omittedStaleCount == 0
            && omittedUnavailableCount == 0
            && selectionOmittedCount == 0
    }

    private static func hasConsistentSources(
        _ facts: [AskGraphFactSynthesisEvidence]
    ) -> Bool {
        var evidenceBySegmentID: [UUID: MeetingMemoryGraphEvidence] = [:]
        for fact in facts {
            for source in fact.fact.evidence {
                if let existing = evidenceBySegmentID[source.segmentID],
                   existing != source {
                    return false
                }
                evidenceBySegmentID[source.segmentID] = source
            }
        }
        return true
    }
}

/// Typed state of the graph lane admitted to synthesis. Abstention and
/// operational failure remain explicit; malformed provenance is never sent to
/// a model and does not masquerade as an empty factual result.
public enum AskGraphFactSynthesisLane: Equatable, Sendable {
    case notRequested
    case facts(AskGraphFactSynthesisPage)
    case abstained(MeetingMemoryGraphQueryAbstention)
    case unavailable
    case invalidEvidence
    case selectionBudgetExceeded(AskFactAwareSelectionDisclosure)
}

/// Complete, storage-independent answer material. Transcript citations and
/// graph facts remain separately typed so a generator cannot reinterpret graph
/// popularity as transcript relevance.
public struct AskSynthesisInput: Equatable, Sendable {
    public let transcriptCitations: [AskCitation]
    public let graphFacts: AskGraphFactSynthesisLane
    public let selection: AskFactAwareSelectionDisclosure?

    public init(
        transcriptCitations: [AskCitation],
        graphFacts: AskGraphFactSynthesisLane = .notRequested,
        selection: AskFactAwareSelectionDisclosure? = nil
    ) {
        self.transcriptCitations = transcriptCitations
        self.graphFacts = graphFacts
        self.selection = selection
    }

    /// Fact-aware synthesis is deliberately stricter than transcript-only Ask:
    /// both independently ranked transcript evidence and a valid source-backed
    /// fact page must be present. Graph facts never replace transcript retrieval.
    public var isFactAwareGenerationReady: Bool {
        guard Self.hasExactTranscriptEvidence(transcriptCitations),
              case .facts(let page) = graphFacts,
              !page.facts.isEmpty,
              let selection,
              selection.matches(
                  transcriptCitations: transcriptCitations,
                  graphPage: page)
        else { return false }

        let transcriptByID = Dictionary(uniqueKeysWithValues:
            transcriptCitations.compactMap { citation in
                citation.segmentID.map { ($0, citation) }
            })
        for fact in page.facts {
            for source in fact.sourceSegments {
                guard let segmentID = source.segmentID,
                      let transcript = transcriptByID[segmentID]
                else { continue }
                guard Self.sameExactSource(transcript, source) else {
                    return false
                }
            }
        }
        return true
    }

    private static func hasExactTranscriptEvidence(
        _ citations: [AskCitation]
    ) -> Bool {
        guard !citations.isEmpty,
              citations.allSatisfy({ citation in
                  citation.segmentID != nil
                      && citation.timestamp.isFinite
                      && citation.timestamp >= 0
                      && citation.transcriptRevision >= 0
                      && !citation.meetingTitle.trimmingCharacters(
                          in: .whitespacesAndNewlines).isEmpty
                      && !citation.text.trimmingCharacters(
                          in: .whitespacesAndNewlines).isEmpty
              })
        else { return false }
        let ids = citations.compactMap(\.segmentID)
        return Set(ids).count == ids.count
    }

    private static func sameExactSource(
        _ lhs: AskCitation,
        _ rhs: AskCitation
    ) -> Bool {
        lhs.segmentID == rhs.segmentID
            && lhs.meetingID == rhs.meetingID
            && lhs.meetingTitle == rhs.meetingTitle
            && lhs.timestamp == rhs.timestamp
            && lhs.transcriptRevision == rhs.transcriptRevision
            && lhs.text == rhs.text
    }
}

public extension AskEvidenceBundle {
    /// Converts source-backed graph results into exact synthesis material. Any
    /// broken primary/duplicate source identity fails only the graph lane.
    var synthesisInput: AskSynthesisInput {
        let synthesisLane: AskGraphFactSynthesisLane
        switch graphFacts {
        case .notRequested:
            synthesisLane = .notRequested
        case .unavailable:
            synthesisLane = .unavailable
        case .result(.abstained(let reason)):
            synthesisLane = .abstained(reason)
        case .result(.facts(let page)):
            synthesisLane = AskGraphFactSynthesisPage(page: page).map {
                .facts($0)
            } ?? .invalidEvidence
        }
        return AskSynthesisInput(
            transcriptCitations: transcriptCitations,
            graphFacts: synthesisLane)
    }
}

/// Answer generated from an explicit two-lane evidence bundle. The exact
/// source material remains available even when local generation is absent.
public struct AskEvidenceBundleAnswer: Equatable, Sendable {
    public let question: String
    public let generatedText: String?
    public let evidence: AskEvidenceBundle

    public init(
        question: String,
        generatedText: String?,
        evidence: AskEvidenceBundle
    ) {
        self.question = question
        self.generatedText = generatedText
        self.evidence = evidence
    }
}
