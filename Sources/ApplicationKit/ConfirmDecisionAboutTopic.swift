import Foundation
import PortavozCore
import StorageKit

/// The topic half of the gesture. `none` confirms the decision alone;
/// `existing` links to a topic the user picked from the suggestion list;
/// `labeled` resolves a typed label — one exact alias match links to that
/// topic, no match creates a new one, and an ambiguous label refuses rather
/// than guessing which topic the user meant.
public enum DecisionTopicChoice: Equatable, Sendable {
    case none
    case existing(TopicID)
    case labeled(String)
}

/// One explicit user gesture over a generated decision observation: promote it
/// to durable decision truth, and optionally assert what it is about.
public struct ConfirmDecisionAboutTopicRequest: Equatable, Sendable {
    public let observationID: SummaryDecisionID
    public let meetingID: MeetingID
    /// The evidence segment the user was reading; a newly created topic is
    /// grounded on it, exactly like a manual topic link.
    public let evidenceSegmentID: UUID
    public let sourceTranscriptRevision: Int
    public let topic: DecisionTopicChoice
    public let confirmedAt: Date

    public init(
        observationID: SummaryDecisionID,
        meetingID: MeetingID,
        evidenceSegmentID: UUID,
        sourceTranscriptRevision: Int,
        topic: DecisionTopicChoice,
        confirmedAt: Date = Date()
    ) {
        self.observationID = observationID
        self.meetingID = meetingID
        self.evidenceSegmentID = evidenceSegmentID
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.topic = topic
        self.confirmedAt = confirmedAt
    }
}

public struct DecisionAboutTopicOutcome: Equatable, Sendable {
    public let observationID: SummaryDecisionID
    public let decisionID: DecisionID
    public let topicLabel: String?

    public init(
        observationID: SummaryDecisionID,
        decisionID: DecisionID,
        topicLabel: String?
    ) {
        self.observationID = observationID
        self.decisionID = decisionID
        self.topicLabel = topicLabel
    }
}

public enum ConfirmDecisionAboutTopicError: Error, Equatable {
    /// The typed label matches aliases of more than one topic. The user must
    /// pick one from the list; the gesture never guesses identity.
    case ambiguousTopicLabel(String)
    case emptyTopicLabel
}

/// Everything the gesture composes. All five operations already exist as
/// independent authority; this protocol only names the slice of MeetingStore
/// the use case may see.
public protocol DecisionAboutTopicStore: Sendable {
    func decisionObservationConfirmations(
        for observationIDs: [SummaryDecisionID]
    ) async throws -> [DecisionObservationConfirmationState]
    func confirmDecision(
        _ confirmation: DecisionConfirmation
    ) async throws -> DecisionContinuity
    func topics(matchingAlias alias: String) async throws -> [Topic]
    func createTopicAndLink(
        _ proposal: TopicLinkProposal
    ) async throws -> ConfirmedTopicLink
    func confirmDecisionTopicLink(
        _ confirmation: DecisionTopicLinkConfirmation
    ) async throws -> DecisionTopicLinkContinuity
}

extension MeetingStore: DecisionAboutTopicStore {}

/// Composes the two confirmations of the gesture. Re-running it on an already
/// confirmed observation reuses the existing decision instead of failing, so
/// the user can add a topic link later without re-confirming.
public struct ConfirmDecisionAboutTopic: ApplicationUseCase {
    private let store: any DecisionAboutTopicStore

    public init(store: any DecisionAboutTopicStore) {
        self.store = store
    }

    public func execute(
        _ request: ConfirmDecisionAboutTopicRequest
    ) async throws -> DecisionAboutTopicOutcome {
        let decisionID: DecisionID
        if let existing = try await store.decisionObservationConfirmations(
            for: [request.observationID]).first {
            decisionID = existing.decisionID
        } else {
            let confirmation = DecisionConfirmation(
                observationID: request.observationID,
                confirmedAt: request.confirmedAt)
            _ = try await store.confirmDecision(confirmation)
            decisionID = confirmation.decisionID
        }

        let topicID: TopicID?
        let topicLabel: String?
        switch request.topic {
        case .none:
            topicID = nil
            topicLabel = nil
        case .existing(let id):
            topicID = id
            topicLabel = nil
        case .labeled(let raw):
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else {
                throw ConfirmDecisionAboutTopicError.emptyTopicLabel
            }
            let matches = try await store.topics(matchingAlias: label)
            switch matches.count {
            case 0:
                let created = try await store.createTopicAndLink(
                    TopicLinkProposal(
                        meetingID: request.meetingID,
                        segmentID: request.evidenceSegmentID,
                        sourceTranscriptRevision: request.sourceTranscriptRevision,
                        observedLabel: label,
                        language: nil,
                        origin: .manual,
                        confirmedAt: request.confirmedAt))
                topicID = created.topic.id
                topicLabel = created.topic.preferredLabel
            case 1:
                topicID = matches[0].id
                topicLabel = matches[0].preferredLabel
            default:
                throw ConfirmDecisionAboutTopicError.ambiguousTopicLabel(label)
            }
        }

        if let topicID {
            _ = try await store.confirmDecisionTopicLink(
                DecisionTopicLinkConfirmation(
                    decisionID: decisionID,
                    topicID: topicID,
                    observationID: request.observationID,
                    confirmedAt: request.confirmedAt))
        }
        return DecisionAboutTopicOutcome(
            observationID: request.observationID,
            decisionID: decisionID,
            topicLabel: topicLabel)
    }
}
