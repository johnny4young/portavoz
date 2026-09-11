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

struct AskMemoryFirstDiscussion: Identifiable, Equatable {
    let id: TopicMeetingEvidenceID
    let topicLabel: String
    let meetingID: MeetingID
    let meetingTitle: String
    let occurredAt: Date
    let citation: AskCitation
}

enum AskTopicMemoryJob: Equatable {
    case currentDecisions
    case firstConfirmedDiscussion
    case decisionConflicts
    case changesSince
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
    case decisions([AskMemoryDecision], AskMemoryDisclosure)
    case firstDiscussion(AskMemoryFirstDiscussion)
    case conflicts([AskMemoryDecisionConflict], AskMemoryDisclosure)
    case changesSince(
        [AskMemoryDecisionConflict],
        AskMemoryMeetingAnchor,
        AskMemoryDisclosure)
    case abstained(MeetingMemoryGraphQueryAbstention)
    case invalidEvidence
    case unavailable
}

/// Per-window owner for exact confirmed-topic discovery and topic-memory jobs.
/// Catalog and fact generations are independent, and only a selected TopicID
/// can cross into either source-backed graph query.
@MainActor
@Observable
final class AskTopicMemoryModel {
    struct State {
        fileprivate(set) var topicQuery = ""
        fileprivate(set) var topics: [AskMemoryTopic] = []
        fileprivate(set) var topicsPhase = AskMemoryTopicsPhase.idle
        fileprivate(set) var topicsHaveMore = false
        fileprivate(set) var selectedTopic: AskMemoryTopic?
        fileprivate(set) var selectedJob = AskTopicMemoryJob.currentDecisions
        fileprivate(set) var outcome = AskTopicMemoryOutcome.idle
    }

    static let visibleTopicLimit = 20
    private static let topicRequestLimit = visibleTopicLimit + 1
    private static let decisionLimit = DecisionHistoryQuery.maximumItemLimit
    private static let conflictLimit = DecisionConflictsQuery.maximumItemLimit
    private static let changesSinceLimit = ChangeSinceQuery.maximumItemLimit

    private(set) var state = State()
    let meetingAnchors: AskMeetingAnchorModel

    private let client: any AskMemoryModelClient
    private let searchDelay: Duration
    private var topicsTask: Task<Void, Never>?
    private var factTask: Task<Void, Never>?
    private var topicsGeneration = 0
    private var factGeneration = 0

    init(
        client: any AskMemoryModelClient,
        searchDelay: Duration = .milliseconds(200)
    ) {
        self.client = client
        self.searchDelay = searchDelay
        meetingAnchors = AskMeetingAnchorModel(
            client: client,
            searchDelay: searchDelay)
    }

    isolated deinit {
        topicsTask?.cancel()
        factTask?.cancel()
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
        cancelFactLoad()
        meetingAnchors.reset()
        startTopicSearch(delay: searchDelay)
    }

    func selectTopic(_ id: TopicID) {
        guard let topic = state.topics.first(where: { $0.id == id }) else {
            return
        }
        cancelTopicSearch()
        cancelFactLoad()
        state.topicQuery = topic.label
        state.topics = []
        state.topicsHaveMore = false
        state.topicsPhase = .ready
        state.selectedTopic = topic
        state.outcome = .idle
        meetingAnchors.reset()
        if state.selectedJob == .changesSince {
            meetingAnchors.activate()
        }
    }

    func clearTopicSelection() {
        cancelFactLoad()
        state.topicQuery = ""
        state.selectedTopic = nil
        state.outcome = .idle
        meetingAnchors.reset()
        startTopicSearch(delay: .zero)
    }

    func retryTopicSearch() {
        state.selectedTopic = nil
        state.outcome = .idle
        meetingAnchors.reset()
        startTopicSearch(delay: .zero)
    }

    func selectJob(_ job: AskTopicMemoryJob) {
        guard job != state.selectedJob else { return }
        cancelFactLoad()
        state.selectedJob = job
        state.outcome = .idle
        meetingAnchors.reset()
        if job == .changesSince, state.selectedTopic != nil {
            meetingAnchors.activate()
        }
    }

    func updateMeetingAnchorQuery(_ value: String) {
        guard state.selectedJob == .changesSince else { return }
        cancelFactLoad()
        state.outcome = .idle
        meetingAnchors.updateQuery(value)
    }

    func selectMeetingAnchor(_ id: MeetingID) {
        guard state.selectedJob == .changesSince else { return }
        cancelFactLoad()
        state.outcome = .idle
        meetingAnchors.selectMeeting(id)
    }

    func clearMeetingAnchorSelection() {
        guard state.selectedJob == .changesSince else { return }
        cancelFactLoad()
        state.outcome = .idle
        meetingAnchors.clearSelection()
    }

    func retryMeetingAnchorSearch() {
        guard state.selectedJob == .changesSince else { return }
        cancelFactLoad()
        state.outcome = .idle
        meetingAnchors.retrySearch()
    }

    func loadSelectedTopicMemory() {
        guard let topic = state.selectedTopic else { return }
        let anchor: AskMemoryMeetingAnchor?
        if state.selectedJob == .changesSince {
            guard let selected = meetingAnchors.state.selectedMeeting else {
                return
            }
            anchor = selected
        } else {
            anchor = nil
        }
        factGeneration += 1
        let requestGeneration = factGeneration
        factTask?.cancel()
        state.outcome = .loading
        startFactLoad(
            for: topic,
            job: state.selectedJob,
            anchor: anchor,
            generation: requestGeneration)
    }

    func loadSelectedTopicDecisions() {
        selectJob(.currentDecisions)
        loadSelectedTopicMemory()
    }

    func cancelPendingWork() {
        cancelTopicSearch()
        cancelFactLoad()
        meetingAnchors.cancelPendingWork()
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

    private func startFactLoad(
        for topic: AskMemoryTopic,
        job: AskTopicMemoryJob,
        anchor: AskMemoryMeetingAnchor?,
        generation requestGeneration: Int
    ) {
        factTask = Task { [weak self, client] in
            do {
                let result: MeetingMemoryGraphQueryResult
                switch job {
                case .currentDecisions:
                    result = try await client.loadAskMemoryDecisionHistory(
                        topicID: topic.id,
                        limit: Self.decisionLimit)
                case .firstConfirmedDiscussion:
                    result = try await client.loadAskMemoryTopicFirstDiscussion(
                        topicID: topic.id)
                case .decisionConflicts:
                    result = try await client.loadAskMemoryDecisionConflicts(
                        topicID: topic.id,
                        limit: Self.conflictLimit)
                case .changesSince:
                    guard let anchor else { return }
                    result = try await client.loadAskMemoryChangesSince(
                        topicID: topic.id,
                        sinceMeetingID: anchor.id,
                        limit: Self.changesSinceLimit)
                }
                try Task.checkCancellation()
                guard let self,
                      self.factGeneration == requestGeneration,
                      self.state.selectedTopic?.id == topic.id,
                      self.state.selectedJob == job,
                      self.anchorIsCurrent(anchor, for: job)
                else { return }
                self.state.outcome = Self.prepareOutcome(
                    result,
                    expectedTopic: topic,
                    job: job,
                    anchor: anchor)
                self.factTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.factGeneration == requestGeneration,
                      self.state.selectedTopic?.id == topic.id,
                      self.state.selectedJob == job,
                      self.anchorIsCurrent(anchor, for: job)
                else { return }
                self.state.outcome = .unavailable
                self.factTask = nil
            }
        }
    }

    private func cancelTopicSearch() {
        topicsGeneration += 1
        topicsTask?.cancel()
        topicsTask = nil
    }

    private func cancelFactLoad() {
        factGeneration += 1
        factTask?.cancel()
        factTask = nil
    }

    private func anchorIsCurrent(
        _ anchor: AskMemoryMeetingAnchor?,
        for job: AskTopicMemoryJob
    ) -> Bool {
        switch job {
        case .changesSince:
            return meetingAnchors.state.selectedMeeting?.id == anchor?.id
        case .currentDecisions, .firstConfirmedDiscussion, .decisionConflicts:
            return anchor == nil
        }
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
        expectedTopic: AskMemoryTopic,
        job: AskTopicMemoryJob,
        anchor: AskMemoryMeetingAnchor?
    ) -> AskTopicMemoryOutcome {
        switch result {
        case .abstained(let reason):
            return .abstained(reason)
        case .facts(let page):
            switch job {
            case .currentDecisions:
                return prepareDecisions(page, expectedTopic: expectedTopic)
            case .firstConfirmedDiscussion:
                guard let discussion = prepareFirstDiscussion(
                    page,
                    expectedTopic: expectedTopic)
                else { return .invalidEvidence }
                return .firstDiscussion(discussion)
            case .decisionConflicts:
                return prepareConflicts(page)
            case .changesSince:
                guard let anchor,
                      let prepared = AskTopicDecisionRelationshipPage.prepare(
                        page,
                        maximumCount: changesSinceLimit)
                else { return .invalidEvidence }
                return .changesSince(prepared.0, anchor, prepared.1)
            }
        }
    }

    private static func prepareConflicts(
        _ page: MeetingMemoryGraphFactPage
    ) -> AskTopicMemoryOutcome {
        guard let prepared = AskTopicDecisionRelationshipPage.prepare(
            page,
            maximumCount: conflictLimit)
        else { return .invalidEvidence }
        return .conflicts(prepared.0, prepared.1)
    }
}

extension AskTopicMemoryModel {
    private static func prepareDecisions(
        _ page: MeetingMemoryGraphFactPage,
        expectedTopic: AskMemoryTopic
    ) -> AskTopicMemoryOutcome {
        guard page.facts.count <= decisionLimit,
              let synthesis = AskGraphFactSynthesisPage(page: page)
        else { return .invalidEvidence }
        let decisions = synthesis.facts.compactMap {
            prepareDecision($0, expectedTopic: expectedTopic)
        }
        guard decisions.count == synthesis.facts.count else {
            return .invalidEvidence
        }
        return .decisions(
            decisions,
            AskMemoryDisclosure(
                hasMore: synthesis.hasMore,
                omittedStaleCount: synthesis.omittedStaleCount,
                omittedUnavailableCount: synthesis.omittedUnavailableCount))
    }

    private static func prepareFirstDiscussion(
        _ page: MeetingMemoryGraphFactPage,
        expectedTopic: AskMemoryTopic
    ) -> AskMemoryFirstDiscussion? {
        guard page.facts.count == 1,
              let synthesis = AskGraphFactSynthesisPage(page: page),
              synthesis.isComplete,
              synthesis.facts.count == 1,
              let evidence = synthesis.facts.first,
              evidence.sourceSegments.count == 1,
              evidence.fact.evidence.count == 1
        else { return nil }

        let fact = evidence.fact
        let source = fact.evidence[0]
        let citation = evidence.sourceSegments[0]
        guard case .topicEvidence(let evidenceID) = fact.id,
              fact.kind == .topicDiscussedInMeeting,
              case .topic(let topicID) = fact.subject,
              topicID == expectedTopic.id,
              case .meeting(let meetingID) = fact.object,
              fact.status == .confirmed,
              fact.subjectText == expectedTopic.label,
              fact.objectText == citation.meetingTitle,
              source.meetingID == meetingID,
              citation.meetingID == meetingID,
              source.segmentID == fact.primaryEvidenceSegmentID,
              citation.segmentID == fact.primaryEvidenceSegmentID,
              fact.occurredAt
                == source.meetingStartedAt.addingTimeInterval(source.startTime)
        else { return nil }

        return AskMemoryFirstDiscussion(
            id: evidenceID,
            topicLabel: expectedTopic.label,
            meetingID: meetingID,
            meetingTitle: citation.meetingTitle,
            occurredAt: fact.occurredAt,
            citation: citation)
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
