import PortavozCore
import StorageKit

/// One caller-resolved graph fact request. Natural-language extraction and
/// cross-lane selection remain outside this exact retrieval boundary.
public enum AskGraphFactQuery: Equatable, Sendable {
    case commitmentBlockers(CommitmentBlockerQuery)
    case topicFirstDiscussion(TopicFirstDiscussionQuery)
    case personCommitments(PersonCommitmentsQuery)
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

    public init(store: MeetingStore) {
        blockers = store
        topics = store
        commitments = store
    }

    public init(
        blockers: any CommitmentBlockerFactReading,
        topics: any TopicFirstDiscussionReading,
        commitments: any PersonCommitmentFactReading
    ) {
        self.blockers = blockers
        self.topics = topics
        self.commitments = commitments
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

/// Final evidence from two independent lanes. Answer synthesis still consumes
/// transcript citations only until its typed-fact contract is introduced.
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
