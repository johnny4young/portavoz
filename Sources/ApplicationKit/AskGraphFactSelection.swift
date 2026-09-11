import Foundation

/// Closed disclosure for the final fact-aware context selection. Candidate
/// counts describe only the already-retrieved exact material; storage overflow
/// and stale/unavailable omissions remain on the graph page itself.
public struct AskFactAwareSelectionDisclosure: Equatable, Sendable {
    public let transcriptCandidateCount: Int
    public let selectedTranscriptCount: Int
    public let graphFactCandidateCount: Int
    public let selectedGraphFactCount: Int
    public let additionalGraphSourceCount: Int
    public let omittedGraphFactCount: Int

    public init?(
        transcriptCandidateCount: Int,
        selectedTranscriptCount: Int,
        graphFactCandidateCount: Int,
        selectedGraphFactCount: Int,
        additionalGraphSourceCount: Int,
        omittedGraphFactCount: Int
    ) {
        guard transcriptCandidateCount >= selectedTranscriptCount,
              selectedTranscriptCount > 0,
              graphFactCandidateCount >= selectedGraphFactCount,
              selectedGraphFactCount >= 0,
              selectedGraphFactCount <= selectedTranscriptCount,
              additionalGraphSourceCount >= 0,
              omittedGraphFactCount
                == graphFactCandidateCount - selectedGraphFactCount
        else { return nil }
        self.transcriptCandidateCount = transcriptCandidateCount
        self.selectedTranscriptCount = selectedTranscriptCount
        self.graphFactCandidateCount = graphFactCandidateCount
        self.selectedGraphFactCount = selectedGraphFactCount
        self.additionalGraphSourceCount = additionalGraphSourceCount
        self.omittedGraphFactCount = omittedGraphFactCount
    }

    func matches(
        transcriptCitations: [AskCitation],
        graphPage: AskGraphFactSynthesisPage
    ) -> Bool {
        let transcriptIDs = Set(transcriptCitations.compactMap(\.segmentID))
        let graphSourceIDs = Set(graphPage.facts.flatMap {
            $0.sourceSegments.compactMap(\.segmentID)
        })
        return selectedTranscriptCount == transcriptCitations.count
            && selectedGraphFactCount == graphPage.facts.count
            && graphFactCandidateCount
                == graphPage.facts.count + graphPage.selectionOmittedCount
            && omittedGraphFactCount == graphPage.selectionOmittedCount
            && additionalGraphSourceCount
                == graphSourceIDs.subtracting(transcriptIDs).count
    }
}

/// Deterministic post-RRF selector for fact-aware generation. Transcript rank
/// is reserved first; facts keep query order, stay atomic with all exact
/// sources, and may never outnumber the selected transcript citations.
public struct AskFactAwareSelectionPolicy: Equatable, Sendable {
    public static let production: AskFactAwareSelectionPolicy = {
        guard let policy = AskFactAwareSelectionPolicy(
            maximumTranscriptCitations: 6,
            maximumGraphFacts: 4,
            maximumAdditionalGraphSources: 8)
        else {
            preconditionFailure("The production Ask selection policy is invalid")
        }
        return policy
    }()

    public let maximumTranscriptCitations: Int
    public let maximumGraphFacts: Int
    public let maximumAdditionalGraphSources: Int

    public init?(
        maximumTranscriptCitations: Int,
        maximumGraphFacts: Int,
        maximumAdditionalGraphSources: Int
    ) {
        guard maximumTranscriptCitations > 0,
              maximumGraphFacts > 0,
              maximumAdditionalGraphSources >= 0
        else { return nil }
        self.maximumTranscriptCitations = maximumTranscriptCitations
        self.maximumGraphFacts = maximumGraphFacts
        self.maximumAdditionalGraphSources = maximumAdditionalGraphSources
    }

    public func select(_ input: AskSynthesisInput) -> AskSynthesisInput {
        guard input.selection == nil,
              case .facts(let page) = input.graphFacts
        else { return input }
        let transcript = Array(input.transcriptCitations.prefix(
            maximumTranscriptCitations))
        guard !transcript.isEmpty else { return input }

        let transcriptIDs = Set(transcript.compactMap(\.segmentID))
        let factLimit = min(maximumGraphFacts, transcript.count)
        var additionalSourceIDs: Set<UUID> = []
        var selectedCount = 0

        for fact in page.facts.prefix(factLimit) {
            let incrementalSources = Set(
                fact.sourceSegments.compactMap(\.segmentID))
                .subtracting(transcriptIDs)
                .subtracting(additionalSourceIDs)
            guard additionalSourceIDs.count + incrementalSources.count
                    <= maximumAdditionalGraphSources
            else { break }
            selectedCount += 1
            additionalSourceIDs.formUnion(incrementalSources)
        }

        // Build the narrowed page first so the disclosure can only ever
        // describe material that actually survived selection.
        guard let selectedPage = page.selectingPrefix(selectedCount) else {
            let omitted = page.facts.count + page.selectionOmittedCount
            guard let disclosure = AskFactAwareSelectionDisclosure(
                transcriptCandidateCount: input.transcriptCitations.count,
                selectedTranscriptCount: transcript.count,
                graphFactCandidateCount: omitted,
                selectedGraphFactCount: 0,
                additionalGraphSourceCount: 0,
                omittedGraphFactCount: omitted)
            else { return input }
            return AskSynthesisInput(
                transcriptCitations: transcript,
                graphFacts: .selectionBudgetExceeded(disclosure),
                selection: disclosure)
        }
        guard let disclosure = AskFactAwareSelectionDisclosure(
            transcriptCandidateCount: input.transcriptCitations.count,
            selectedTranscriptCount: transcript.count,
            graphFactCandidateCount:
                selectedPage.facts.count + selectedPage.selectionOmittedCount,
            selectedGraphFactCount: selectedPage.facts.count,
            additionalGraphSourceCount: additionalSourceIDs.count,
            omittedGraphFactCount: selectedPage.selectionOmittedCount)
        else { return input }
        return AskSynthesisInput(
            transcriptCitations: transcript,
            graphFacts: .facts(selectedPage),
            selection: disclosure)
    }
}

public extension AskSynthesisInput {
    func selecting(
        using policy: AskFactAwareSelectionPolicy = .production
    ) -> AskSynthesisInput {
        policy.select(self)
    }
}
