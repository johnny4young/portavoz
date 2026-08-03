import Foundation

public enum MeetingMemoryGraphScopeKind: String, CaseIterable, Codable, Sendable {
    case meeting
    case person
    case topic
    case decision
    case commitment
}

/// Versioned identity of the disposable relational graph projection.
///
/// Changing its contract intentionally admits a fresh durable maintenance
/// operation and rebuilds every typed edge from authoritative local records.
public enum MeetingMemoryGraphProjectionProfile {
    public static let fingerprint = OperationFingerprint.make(
        version: "meeting-memory-graph-projection-v1",
        components: [
            "meeting-person-v1",
            "meeting-topic-v1",
            "meeting-decision-v1",
            "meeting-commitment-v1",
            "commitment-person-v1"
        ])
}

public struct MeetingMemoryGraphProjectionResult: Equatable, Sendable {
    public let rebuiltScopes: Int
    public let publishedEdges: Int
    public let resetProjection: Bool
    public let pausedByPolicy: Bool

    public init(
        rebuiltScopes: Int = 0,
        publishedEdges: Int = 0,
        resetProjection: Bool = false,
        pausedByPolicy: Bool = false
    ) {
        self.rebuiltScopes = rebuiltScopes
        self.publishedEdges = publishedEdges
        self.resetProjection = resetProjection
        self.pausedByPolicy = pausedByPolicy
    }

    public static let empty = MeetingMemoryGraphProjectionResult()
    public static let paused = MeetingMemoryGraphProjectionResult(pausedByPolicy: true)

    public static func + (
        left: MeetingMemoryGraphProjectionResult,
        right: MeetingMemoryGraphProjectionResult
    ) -> MeetingMemoryGraphProjectionResult {
        MeetingMemoryGraphProjectionResult(
            rebuiltScopes: left.rebuiltScopes + right.rebuiltScopes,
            publishedEdges: left.publishedEdges + right.publishedEdges,
            resetProjection: left.resetProjection || right.resetProjection,
            pausedByPolicy: left.pausedByPolicy || right.pausedByPolicy)
    }

    public static func += (
        left: inout MeetingMemoryGraphProjectionResult,
        right: MeetingMemoryGraphProjectionResult
    ) {
        left = left + right
    }
}

public struct MeetingMemoryGraphProjectionSnapshot: Equatable, Sendable {
    public struct MeetingPersonEdge: Hashable, Sendable {
        public let meetingID: MeetingID
        public let personID: PersonID

        public init(meetingID: MeetingID, personID: PersonID) {
            self.meetingID = meetingID
            self.personID = personID
        }
    }

    public struct MeetingTopicEdge: Hashable, Sendable {
        public let meetingID: MeetingID
        public let topicID: TopicID

        public init(meetingID: MeetingID, topicID: TopicID) {
            self.meetingID = meetingID
            self.topicID = topicID
        }
    }

    public struct MeetingDecisionEdge: Hashable, Sendable {
        public let meetingID: MeetingID
        public let decisionID: DecisionID

        public init(meetingID: MeetingID, decisionID: DecisionID) {
            self.meetingID = meetingID
            self.decisionID = decisionID
        }
    }

    public struct MeetingCommitmentEdge: Hashable, Sendable {
        public let meetingID: MeetingID
        public let commitmentID: CommitmentID

        public init(meetingID: MeetingID, commitmentID: CommitmentID) {
            self.meetingID = meetingID
            self.commitmentID = commitmentID
        }
    }

    public struct CommitmentPersonEdge: Hashable, Sendable {
        public let commitmentID: CommitmentID
        public let personID: PersonID

        public init(commitmentID: CommitmentID, personID: PersonID) {
            self.commitmentID = commitmentID
            self.personID = personID
        }
    }

    public let meetingPeople: [MeetingPersonEdge]
    public let meetingTopics: [MeetingTopicEdge]
    public let meetingDecisions: [MeetingDecisionEdge]
    public let meetingCommitments: [MeetingCommitmentEdge]
    public let commitmentPeople: [CommitmentPersonEdge]

    public init(
        meetingPeople: [MeetingPersonEdge],
        meetingTopics: [MeetingTopicEdge],
        meetingDecisions: [MeetingDecisionEdge],
        meetingCommitments: [MeetingCommitmentEdge],
        commitmentPeople: [CommitmentPersonEdge]
    ) {
        self.meetingPeople = meetingPeople
        self.meetingTopics = meetingTopics
        self.meetingDecisions = meetingDecisions
        self.meetingCommitments = meetingCommitments
        self.commitmentPeople = commitmentPeople
    }
}
