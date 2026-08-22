import ApplicationKit
import Foundation
import Observation
import PortavozCore

struct AskMemoryTopic: Identifiable, Equatable {
    let id: TopicID
    let label: String
}

struct AskMemoryDecision: Identifiable, Equatable {
    let id: DecisionTopicLinkID
    let decisionID: DecisionID
    let topicLabel: String
    let statement: String
    let occurredAt: Date
    let citations: [AskCitation]
    let primaryCitation: AskCitation
}

enum AskMemoryTopicsPhase: Equatable {
    case idle
    case loading
    case ready
    case empty
    case unavailable
}

enum AskTopicMemoryOutcome: Equatable {
    case idle
    case loading
    case facts([AskMemoryDecision], AskMemoryDisclosure)
    case abstained(MeetingMemoryGraphQueryAbstention)
    case invalidEvidence
    case unavailable
}

/// Per-window owner for exact confirmed-topic discovery and current decisions.
/// Catalog and fact generations are independent, and only a selected TopicID
/// can cross into the source-backed decision-history query.
@MainActor
@Observable
final class AskTopicMemoryModel {
    struct State {
        fileprivate(set) var topicQuery = ""
        fileprivate(set) var topics: [AskMemoryTopic] = []
        fileprivate(set) var topicsPhase = AskMemoryTopicsPhase.idle
        fileprivate(set) var topicsHaveMore = false
        fileprivate(set) var selectedTopic: AskMemoryTopic?
        fileprivate(set) var outcome = AskTopicMemoryOutcome.idle
    }

    static let visibleTopicLimit = 20
    private static let topicRequestLimit = visibleTopicLimit + 1
    private static let decisionLimit = DecisionHistoryQuery.maximumItemLimit

    private(set) var state = State()

    private let client: any AskMemoryModelClient
    private let searchDelay: Duration
    private var topicsTask: Task<Void, Never>?
    private var decisionsTask: Task<Void, Never>?
    private var topicsGeneration = 0
    private var decisionsGeneration = 0

    init(
        client: any AskMemoryModelClient,
        searchDelay: Duration = .milliseconds(200)
    ) {
        self.client = client
        self.searchDelay = searchDelay
    }

    isolated deinit {
        topicsTask?.cancel()
        decisionsTask?.cancel()
    }

    func activate() {
        guard state.topicsPhase == .idle else { return }
        startTopicSearch(delay: .zero)
    }

    func updateTopicQuery(_ value: String) {
        guard value != state.topicQuery else { return }
        state.topicQuery = value
        state.selectedTopic = nil
        state.outcome = .idle
        cancelDecisionLoad()
        startTopicSearch(delay: searchDelay)
    }

    func selectTopic(_ id: TopicID) {
        guard let topic = state.topics.first(where: { $0.id == id }) else {
            return
        }
        cancelTopicSearch()
        cancelDecisionLoad()
        state.topicQuery = topic.label
        state.topics = []
        state.topicsHaveMore = false
        state.topicsPhase = .ready
        state.selectedTopic = topic
        state.outcome = .idle
    }

    func clearTopicSelection() {
        cancelDecisionLoad()
        state.topicQuery = ""
        state.selectedTopic = nil
        state.outcome = .idle
        startTopicSearch(delay: .zero)
    }

    func retryTopicSearch() {
        state.selectedTopic = nil
        state.outcome = .idle
        startTopicSearch(delay: .zero)
    }

    func loadSelectedTopicDecisions() {
        guard let topic = state.selectedTopic else { return }
        decisionsGeneration += 1
        let requestGeneration = decisionsGeneration
        decisionsTask?.cancel()
        state.outcome = .loading
        startDecisionLoad(
            for: topic,
            generation: requestGeneration)
    }

    func cancelPendingWork() {
        cancelTopicSearch()
        cancelDecisionLoad()
        if state.topicsPhase == .loading {
            state.topicsPhase = .idle
        }
        if state.outcome == .loading {
            state.outcome = .idle
        }
    }

    private func startTopicSearch(delay: Duration) {
        topicsGeneration += 1
        let requestGeneration = topicsGeneration
        let query = state.topicQuery
        topicsTask?.cancel()
        state.topics = []
        state.topicsHaveMore = false
        state.topicsPhase = .loading
        topicsTask = Task { [weak self, client] in
            do {
                if delay > .zero {
                    try await Task.sleep(for: delay)
                }
                let topics = try await client.searchAskMemoryTopics(
                    query,
                    limit: Self.topicRequestLimit)
                try Task.checkCancellation()
                guard let self,
                      self.topicsGeneration == requestGeneration
                else { return }
                guard let prepared = Self.prepareTopics(topics) else {
                    self.state.topics = []
                    self.state.topicsHaveMore = false
                    self.state.topicsPhase = .unavailable
                    self.topicsTask = nil
                    return
                }
                self.state.topicsHaveMore = prepared.count > Self.visibleTopicLimit
                self.state.topics = Array(prepared.prefix(Self.visibleTopicLimit))
                self.state.topicsPhase = self.state.topics.isEmpty ? .empty : .ready
                self.topicsTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.topicsGeneration == requestGeneration
                else { return }
                self.state.topics = []
                self.state.topicsHaveMore = false
                self.state.topicsPhase = .unavailable
                self.topicsTask = nil
            }
        }
    }

    private func startDecisionLoad(
        for topic: AskMemoryTopic,
        generation requestGeneration: Int
    ) {
        decisionsTask = Task { [weak self, client] in
            do {
                let result = try await client.loadAskMemoryDecisionHistory(
                    topicID: topic.id,
                    limit: Self.decisionLimit)
                try Task.checkCancellation()
                guard let self,
                      self.decisionsGeneration == requestGeneration,
                      self.state.selectedTopic?.id == topic.id
                else { return }
                self.state.outcome = Self.prepareOutcome(
                    result,
                    expectedTopic: topic)
                self.decisionsTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.decisionsGeneration == requestGeneration,
                      self.state.selectedTopic?.id == topic.id
                else { return }
                self.state.outcome = .unavailable
                self.decisionsTask = nil
            }
        }
    }

    private func cancelTopicSearch() {
        topicsGeneration += 1
        topicsTask?.cancel()
        topicsTask = nil
    }

    private func cancelDecisionLoad() {
        decisionsGeneration += 1
        decisionsTask?.cancel()
        decisionsTask = nil
    }

    private static func prepareTopics(_ topics: [Topic]) -> [AskMemoryTopic]? {
        guard topics.count <= topicRequestLimit else { return nil }
        var ids = Set<TopicID>()
        var prepared: [AskMemoryTopic] = []
        prepared.reserveCapacity(topics.count)
        for topic in topics {
            guard topic.mergedIntoTopicID == nil,
                  ids.insert(topic.id).inserted,
                  let label = TopicAliasNormalizer.displayLabel(topic.preferredLabel)
            else { return nil }
            prepared.append(AskMemoryTopic(id: topic.id, label: label))
        }
        return prepared
    }

    private static func prepareOutcome(
        _ result: MeetingMemoryGraphQueryResult,
        expectedTopic: AskMemoryTopic
    ) -> AskTopicMemoryOutcome {
        switch result {
        case .abstained(let reason):
            return .abstained(reason)
        case .facts(let page):
            guard page.facts.count <= decisionLimit,
                  let synthesis = AskGraphFactSynthesisPage(page: page)
            else {
                return .invalidEvidence
            }
            let decisions = synthesis.facts.compactMap {
                prepareDecision($0, expectedTopic: expectedTopic)
            }
            guard decisions.count == synthesis.facts.count else {
                return .invalidEvidence
            }
            return .facts(
                decisions,
                AskMemoryDisclosure(
                    hasMore: synthesis.hasMore,
                    omittedStaleCount: synthesis.omittedStaleCount,
                    omittedUnavailableCount: synthesis.omittedUnavailableCount))
        }
    }

    private static func prepareDecision(
        _ evidence: AskGraphFactSynthesisEvidence,
        expectedTopic: AskMemoryTopic
    ) -> AskMemoryDecision? {
        let fact = evidence.fact
        guard case .decisionAboutness(let linkID) = fact.id,
              fact.kind == .decisionAboutTopic,
              case .decision(let decisionID) = fact.subject,
              case .topic(let topicID) = fact.object,
              topicID == expectedTopic.id,
              fact.status == .confirmed,
              fact.objectText == expectedTopic.label,
              !fact.subjectText.trimmingCharacters(
                  in: .whitespacesAndNewlines).isEmpty,
              let primary = evidence.sourceSegments.first(where: {
                  $0.segmentID == fact.primaryEvidenceSegmentID
              })
        else { return nil }
        return AskMemoryDecision(
            id: linkID,
            decisionID: decisionID,
            topicLabel: expectedTopic.label,
            statement: fact.subjectText,
            occurredAt: fact.occurredAt,
            citations: evidence.sourceSegments,
            primaryCitation: primary)
    }
}
