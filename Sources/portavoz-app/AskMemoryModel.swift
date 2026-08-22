import ApplicationKit
import Foundation
import Observation
import PortavozCore

/// Narrow presentation client for the first explicit, identity-safe graph
/// surface. Free-form Ask remains on `AskModelClient` and cannot infer this
/// exact person selection from question text.
@MainActor
protocol AskMemoryModelClient: AnyObject {
    func searchAskMemoryPeople(
        _ query: String,
        limit: Int
    ) async throws -> [Person]
    func loadAskMemoryPersonCommitments(
        personID: PersonID,
        limit: Int
    ) async throws -> MeetingMemoryGraphQueryResult
    func loadAskMemoryCommitmentBlockers(
        commitmentID: CommitmentID,
        limit: Int
    ) async throws -> MeetingMemoryGraphQueryResult
    func searchAskMemoryTopics(
        _ query: String,
        limit: Int
    ) async throws -> [Topic]
    func loadAskMemoryDecisionHistory(
        topicID: TopicID,
        limit: Int
    ) async throws -> MeetingMemoryGraphQueryResult
    func loadAskMemoryTopicFirstDiscussion(
        topicID: TopicID
    ) async throws -> MeetingMemoryGraphQueryResult
    func loadAskMemoryDecisionConflicts(
        topicID: TopicID,
        limit: Int
    ) async throws -> MeetingMemoryGraphQueryResult
}

struct AskMemoryPerson: Identifiable, Equatable {
    let id: PersonID
    let name: String
}

struct AskMemoryCommitment: Identifiable, Equatable {
    let id: CommitmentID
    let personName: String
    let title: String
    let occurredAt: Date
    let citations: [AskCitation]
    let primaryCitation: AskCitation
}

struct AskMemoryBlocker: Identifiable, Equatable {
    let id: DecisionCommitmentBlockerID
    let decisionID: DecisionID
    let commitmentID: CommitmentID
    let decisionStatement: String
    let commitmentTitle: String
    let occurredAt: Date
    let citations: [AskCitation]
    let primaryCitation: AskCitation
}

struct AskMemoryDisclosure: Equatable {
    let hasMore: Bool
    let omittedStaleCount: Int
    let omittedUnavailableCount: Int
}

enum AskMemoryPeoplePhase: Equatable {
    case idle
    case loading
    case ready
    case empty
    case unavailable
}

enum AskMemoryOutcome: Equatable {
    case idle
    case loading
    case facts([AskMemoryCommitment], AskMemoryDisclosure)
    case abstained(MeetingMemoryGraphQueryAbstention)
    case invalidEvidence
    case unavailable
}

enum AskMemoryBlockerOutcome: Equatable {
    case idle
    case loading
    case facts([AskMemoryBlocker], AskMemoryDisclosure)
    case abstained(MeetingMemoryGraphQueryAbstention)
    case invalidEvidence
    case unavailable
}

/// Per-window owner for exact confirmed-memory discovery and facts. Search and
/// fact generations are independent so stale catalog reads cannot replace a
/// newer query and a late graph result cannot publish after person selection.
@MainActor
@Observable
final class AskMemoryModel {
    struct State {
        fileprivate(set) var personQuery = ""
        fileprivate(set) var people: [AskMemoryPerson] = []
        fileprivate(set) var peoplePhase = AskMemoryPeoplePhase.idle
        fileprivate(set) var peopleHasMore = false
        fileprivate(set) var selectedPerson: AskMemoryPerson?
        fileprivate(set) var outcome = AskMemoryOutcome.idle
        fileprivate(set) var selectedCommitmentIDForBlockers: CommitmentID?
        fileprivate(set) var blockerOutcome = AskMemoryBlockerOutcome.idle
    }

    static let visiblePersonLimit = 20
    private static let personRequestLimit = visiblePersonLimit + 1
    private static let commitmentLimit = PersonCommitmentsQuery.maximumItemLimit
    private static let blockerLimit = CommitmentBlockerQuery.maximumItemLimit

    private(set) var state = State()

    private let client: any AskMemoryModelClient
    private let searchDelay: Duration
    private var peopleTask: Task<Void, Never>?
    private var commitmentTask: Task<Void, Never>?
    private var blockerTask: Task<Void, Never>?
    private var peopleGeneration = 0
    private var commitmentGeneration = 0
    private var blockerGeneration = 0

    init(
        client: any AskMemoryModelClient,
        searchDelay: Duration = .milliseconds(200)
    ) {
        self.client = client
        self.searchDelay = searchDelay
    }

    isolated deinit {
        peopleTask?.cancel()
        commitmentTask?.cancel()
        blockerTask?.cancel()
    }

    func activate() {
        guard state.peoplePhase == .idle else { return }
        startPeopleSearch(delay: .zero)
    }

    func updatePersonQuery(_ value: String) {
        guard value != state.personQuery else { return }
        state.personQuery = value
        state.selectedPerson = nil
        state.outcome = .idle
        cancelCommitmentLoad()
        resetBlockerSelection()
        startPeopleSearch(delay: searchDelay)
    }

    func selectPerson(_ id: PersonID) {
        guard let person = state.people.first(where: { $0.id == id }) else {
            return
        }
        cancelPeopleSearch()
        cancelCommitmentLoad()
        resetBlockerSelection()
        state.personQuery = person.name
        state.people = []
        state.peopleHasMore = false
        state.peoplePhase = .ready
        state.selectedPerson = person
        state.outcome = .idle
    }

    func clearPersonSelection() {
        cancelCommitmentLoad()
        resetBlockerSelection()
        state.personQuery = ""
        state.selectedPerson = nil
        state.outcome = .idle
        startPeopleSearch(delay: .zero)
    }

    func retryPeopleSearch() {
        state.selectedPerson = nil
        state.outcome = .idle
        startPeopleSearch(delay: .zero)
    }

    func loadSelectedPersonCommitments() {
        guard let person = state.selectedPerson else { return }
        resetBlockerSelection()
        commitmentGeneration += 1
        let requestGeneration = commitmentGeneration
        commitmentTask?.cancel()
        state.outcome = .loading
        startCommitmentLoad(
            for: person,
            generation: requestGeneration)
    }

    func cancelPendingWork() {
        cancelPeopleSearch()
        cancelCommitmentLoad()
        cancelBlockerLoad()
        if state.peoplePhase == .loading {
            state.peoplePhase = .idle
        }
        if state.outcome == .loading {
            state.outcome = .idle
        }
        if state.blockerOutcome == .loading {
            state.blockerOutcome = .idle
        }
    }

    private func startPeopleSearch(delay: Duration) {
        peopleGeneration += 1
        let requestGeneration = peopleGeneration
        let query = state.personQuery
        peopleTask?.cancel()
        state.people = []
        state.peopleHasMore = false
        state.peoplePhase = .loading
        peopleTask = Task { [weak self, client] in
            do {
                if delay > .zero {
                    try await Task.sleep(for: delay)
                }
                let people = try await client.searchAskMemoryPeople(
                    query,
                    limit: Self.personRequestLimit)
                try Task.checkCancellation()
                guard let self,
                      self.peopleGeneration == requestGeneration
                else { return }
                guard let prepared = Self.preparePeople(people) else {
                    self.state.people = []
                    self.state.peopleHasMore = false
                    self.state.peoplePhase = .unavailable
                    self.peopleTask = nil
                    return
                }
                self.state.peopleHasMore = prepared.count > Self.visiblePersonLimit
                self.state.people = Array(prepared.prefix(Self.visiblePersonLimit))
                self.state.peoplePhase = self.state.people.isEmpty ? .empty : .ready
                self.peopleTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.peopleGeneration == requestGeneration
                else { return }
                self.state.people = []
                self.state.peopleHasMore = false
                self.state.peoplePhase = .unavailable
                self.peopleTask = nil
            }
        }
    }

    private func startCommitmentLoad(
        for person: AskMemoryPerson,
        generation requestGeneration: Int
    ) {
        commitmentTask = Task { [weak self, client] in
            do {
                let result = try await client.loadAskMemoryPersonCommitments(
                    personID: person.id,
                    limit: Self.commitmentLimit)
                try Task.checkCancellation()
                guard let self,
                      self.commitmentGeneration == requestGeneration,
                      self.state.selectedPerson?.id == person.id
                else { return }
                self.state.outcome = Self.prepareOutcome(
                    result,
                    expectedPersonID: person.id)
                self.commitmentTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.commitmentGeneration == requestGeneration,
                      self.state.selectedPerson?.id == person.id
                else { return }
                self.state.outcome = .unavailable
                self.commitmentTask = nil
            }
        }
    }

    private func cancelPeopleSearch() {
        peopleGeneration += 1
        peopleTask?.cancel()
        peopleTask = nil
    }

    private func cancelCommitmentLoad() {
        commitmentGeneration += 1
        commitmentTask?.cancel()
        commitmentTask = nil
    }

    private func cancelBlockerLoad() {
        blockerGeneration += 1
        blockerTask?.cancel()
        blockerTask = nil
    }

    private func resetBlockerSelection() {
        cancelBlockerLoad()
        state.selectedCommitmentIDForBlockers = nil
        state.blockerOutcome = .idle
    }

    private static func preparePeople(_ people: [Person]) -> [AskMemoryPerson]? {
        guard people.count <= personRequestLimit else { return nil }
        var ids = Set<PersonID>()
        var prepared: [AskMemoryPerson] = []
        prepared.reserveCapacity(people.count)
        for person in people {
            guard ids.insert(person.id).inserted,
                  let name = PersonAliasNormalizer.displayName(person.preferredName)
            else { return nil }
            prepared.append(AskMemoryPerson(id: person.id, name: name))
        }
        return prepared
    }

    private static func prepareOutcome(
        _ result: MeetingMemoryGraphQueryResult,
        expectedPersonID: PersonID
    ) -> AskMemoryOutcome {
        switch result {
        case .abstained(let reason):
            return .abstained(reason)
        case .facts(let page):
            guard page.facts.count <= commitmentLimit,
                  let synthesis = AskGraphFactSynthesisPage(page: page)
            else {
                return .invalidEvidence
            }
            let commitments = synthesis.facts.compactMap {
                prepareCommitment($0, expectedPersonID: expectedPersonID)
            }
            guard commitments.count == synthesis.facts.count else {
                return .invalidEvidence
            }
            return .facts(
                commitments,
                AskMemoryDisclosure(
                    hasMore: synthesis.hasMore,
                    omittedStaleCount: synthesis.omittedStaleCount,
                    omittedUnavailableCount: synthesis.omittedUnavailableCount))
        }
    }

    private static func prepareCommitment(
        _ evidence: AskGraphFactSynthesisEvidence,
        expectedPersonID: PersonID
    ) -> AskMemoryCommitment? {
        let fact = evidence.fact
        guard case .commitment(let id) = fact.id,
              fact.kind == .personCommittedTo,
              case .person(let subjectID) = fact.subject,
              subjectID == expectedPersonID,
              case .commitment(let objectID) = fact.object,
              objectID == id,
              fact.status == .active,
              let primary = evidence.sourceSegments.first(where: {
                  $0.segmentID == fact.primaryEvidenceSegmentID
              })
        else { return nil }
        return AskMemoryCommitment(
            id: id,
            personName: fact.subjectText,
            title: fact.objectText,
            occurredAt: fact.occurredAt,
            citations: evidence.sourceSegments,
            primaryCitation: primary)
    }
}

extension AskMemoryModel {
    func loadCommitmentBlockers(for commitmentID: CommitmentID) {
        guard currentCommitment(id: commitmentID) != nil else { return }
        cancelBlockerLoad()
        let requestGeneration = blockerGeneration
        state.selectedCommitmentIDForBlockers = commitmentID
        state.blockerOutcome = .loading
        blockerTask = Task { [weak self, client] in
            do {
                let result = try await client.loadAskMemoryCommitmentBlockers(
                    commitmentID: commitmentID,
                    limit: Self.blockerLimit)
                try Task.checkCancellation()
                guard let self,
                      self.blockerGeneration == requestGeneration,
                      self.state.selectedCommitmentIDForBlockers == commitmentID,
                      let commitment = self.currentCommitment(id: commitmentID)
                else { return }
                self.state.blockerOutcome = Self.prepareBlockerOutcome(
                    result,
                    expectedCommitment: commitment)
                self.blockerTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.blockerGeneration == requestGeneration,
                      self.state.selectedCommitmentIDForBlockers == commitmentID,
                      self.currentCommitment(id: commitmentID) != nil
                else { return }
                self.state.blockerOutcome = .unavailable
                self.blockerTask = nil
            }
        }
    }

    func retryCommitmentBlockers() {
        guard let commitmentID = state.selectedCommitmentIDForBlockers else {
            return
        }
        loadCommitmentBlockers(for: commitmentID)
    }

    private func currentCommitment(
        id commitmentID: CommitmentID
    ) -> AskMemoryCommitment? {
        guard case .facts(let commitments, _) = state.outcome else {
            return nil
        }
        return commitments.first { $0.id == commitmentID }
    }

    private static func prepareBlockerOutcome(
        _ result: MeetingMemoryGraphQueryResult,
        expectedCommitment: AskMemoryCommitment
    ) -> AskMemoryBlockerOutcome {
        switch result {
        case .abstained(let reason):
            return .abstained(reason)
        case .facts(let page):
            guard page.facts.count <= blockerLimit,
                  let synthesis = AskGraphFactSynthesisPage(page: page)
            else {
                return .invalidEvidence
            }
            let blockers = synthesis.facts.compactMap {
                prepareBlocker($0, expectedCommitment: expectedCommitment)
            }
            guard blockers.count == synthesis.facts.count else {
                return .invalidEvidence
            }
            return .facts(
                blockers,
                AskMemoryDisclosure(
                    hasMore: synthesis.hasMore,
                    omittedStaleCount: synthesis.omittedStaleCount,
                    omittedUnavailableCount: synthesis.omittedUnavailableCount))
        }
    }

    private static func prepareBlocker(
        _ evidence: AskGraphFactSynthesisEvidence,
        expectedCommitment: AskMemoryCommitment
    ) -> AskMemoryBlocker? {
        let fact = evidence.fact
        guard case .blocker(let blockerID) = fact.id,
              fact.kind == .decisionBlocksCommitment,
              case .decision(let decisionID) = fact.subject,
              case .commitment(let commitmentID) = fact.object,
              commitmentID == expectedCommitment.id,
              fact.objectText == expectedCommitment.title,
              fact.status == .active,
              let primary = evidence.sourceSegments.first(where: {
                  $0.segmentID == fact.primaryEvidenceSegmentID
              })
        else { return nil }
        return AskMemoryBlocker(
            id: blockerID,
            decisionID: decisionID,
            commitmentID: commitmentID,
            decisionStatement: fact.subjectText,
            commitmentTitle: fact.objectText,
            occurredAt: fact.occurredAt,
            citations: evidence.sourceSegments,
            primaryCitation: primary)
    }
}
