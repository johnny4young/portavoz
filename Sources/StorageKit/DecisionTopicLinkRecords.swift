import Foundation
import GRDB
import PortavozCore

struct DecisionTopicLinkRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "decisionTopicLink"

    var id: String
    var decisionID: String
    var topicID: String
    var status: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(_ link: DecisionTopicLink) {
        id = link.id.rawValue.uuidString
        decisionID = link.decisionID.rawValue.uuidString
        topicID = link.topicID.rawValue.uuidString
        status = link.status.rawValue
        createdAt = link.createdAt
        updatedAt = link.updatedAt
        deletedAt = link.deletedAt
    }

    var link: DecisionTopicLink {
        get throws {
            guard let identity = UUID(uuidString: id),
                  let decision = UUID(uuidString: decisionID),
                  let topic = UUID(uuidString: topicID),
                  let state = DecisionTopicLinkStatus(rawValue: status)
            else {
                throw StorageError.invalidDecisionContinuity(
                    "decision-topic link row is malformed")
            }
            return DecisionTopicLink(
                id: DecisionTopicLinkID(rawValue: identity),
                decisionID: DecisionID(rawValue: decision),
                topicID: TopicID(rawValue: topic),
                status: state,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt)
        }
    }
}

struct DecisionTopicLinkSourceRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "decisionTopicLinkSource"

    var id: String
    var linkID: String
    var summaryDecisionID: String
    var summaryID: String
    var meetingID: String
    var observedStatement: String
    var observedTopicLabel: String
    var sourceTranscriptRevision: Int
    var observedAt: Date
    var linkedAt: Date

    init(_ source: DecisionTopicLinkSource) {
        id = source.id.rawValue.uuidString
        linkID = source.linkID.rawValue.uuidString
        summaryDecisionID = source.observationID.rawValue.uuidString
        summaryID = source.summaryID.rawValue.uuidString
        meetingID = source.meetingID.rawValue.uuidString
        observedStatement = source.observedStatement
        observedTopicLabel = source.observedTopicLabel
        sourceTranscriptRevision = source.sourceTranscriptRevision
        observedAt = source.observedAt
        linkedAt = source.linkedAt
    }

    var source: DecisionTopicLinkSource {
        get throws {
            guard let identity = UUID(uuidString: id),
                  let link = UUID(uuidString: linkID),
                  let observation = UUID(uuidString: summaryDecisionID),
                  let summary = UUID(uuidString: summaryID),
                  let meeting = UUID(uuidString: meetingID)
            else {
                throw StorageError.invalidDecisionContinuity(
                    "decision-topic link source row is malformed")
            }
            return DecisionTopicLinkSource(
                id: DecisionTopicLinkSourceID(rawValue: identity),
                linkID: DecisionTopicLinkID(rawValue: link),
                observationID: SummaryDecisionID(rawValue: observation),
                summaryID: SummaryID(rawValue: summary),
                meetingID: MeetingID(rawValue: meeting),
                observedStatement: observedStatement,
                observedTopicLabel: observedTopicLabel,
                sourceTranscriptRevision: sourceTranscriptRevision,
                observedAt: observedAt,
                linkedAt: linkedAt)
        }
    }
}

struct DecisionTopicLinkEventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "decisionTopicLinkEvent"

    var id: String
    var linkID: String
    var kind: String
    var sourceID: String?
    var occurredAt: Date

    init(_ event: DecisionTopicLinkEvent) {
        id = event.id.rawValue.uuidString
        linkID = event.linkID.rawValue.uuidString
        kind = event.kind.rawValue
        sourceID = event.sourceID?.rawValue.uuidString
        occurredAt = event.occurredAt
    }

    var event: DecisionTopicLinkEvent {
        get throws {
            guard let identity = UUID(uuidString: id),
                  let link = UUID(uuidString: linkID),
                  let eventKind = DecisionTopicLinkEventKind(rawValue: kind)
            else {
                throw StorageError.invalidDecisionContinuity(
                    "decision-topic link event row is malformed")
            }
            let source = try sourceID.map { raw -> DecisionTopicLinkSourceID in
                guard let value = UUID(uuidString: raw) else {
                    throw StorageError.invalidDecisionContinuity(
                        "decision-topic link event source is malformed")
                }
                return DecisionTopicLinkSourceID(rawValue: value)
            }
            return DecisionTopicLinkEvent(
                id: DecisionTopicLinkEventID(rawValue: identity),
                linkID: DecisionTopicLinkID(rawValue: link),
                kind: eventKind,
                sourceID: source,
                occurredAt: occurredAt)
        }
    }
}
