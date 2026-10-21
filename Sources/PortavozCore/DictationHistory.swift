import Foundation

/// How a saved dictation reached its destination. A dispatched paste that could
/// not be observed is never stored as inserted.
public enum DictationRecordDelivery: String, Codable, CaseIterable, Sendable {
    case verified
    case dispatched
    case notDelivered = "not-delivered"
}

/// One finished dictation in the private history. It holds no audio, window
/// title, URL or surrounding text; the destination is the application only.
public struct DictationRecord: Equatable, Identifiable, Sendable {
    public static let maximumTextLength = 20_000
    public static let maximumLabelLength = 256

    public let id: DictationRecordID
    public let createdAt: Date
    public let duration: TimeInterval
    public let text: String
    /// The recognized words before Clean mode; nil when equal or not kept.
    public let originalText: String?
    public let mode: DictationTextMode
    public let language: String?
    public let engine: String
    public let applicationName: String?
    public let applicationBundleID: String?
    public let delivery: DictationRecordDelivery

    public init(
        id: DictationRecordID,
        createdAt: Date,
        duration: TimeInterval,
        text: String,
        originalText: String?,
        mode: DictationTextMode,
        language: String?,
        engine: String,
        applicationName: String?,
        applicationBundleID: String?,
        delivery: DictationRecordDelivery
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.text = text
        self.originalText = originalText == text ? nil : originalText
        self.mode = mode
        self.language = language
        self.engine = engine
        self.applicationName = applicationName
        self.applicationBundleID = applicationBundleID
        self.delivery = delivery
    }

    /// Lengths count Unicode scalars, as SQLite's `length()` does.
    public var isValid: Bool {
        func fits(_ value: String?, _ limit: Int) -> Bool { (value?.unicodeScalars.count ?? 0) <= limit }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && fits(text, Self.maximumTextLength) && fits(originalText, Self.maximumTextLength)
            && duration.isFinite && duration >= 0
            && createdAt.timeIntervalSinceReferenceDate.isFinite
            && !engine.isEmpty && fits(engine, Self.maximumLabelLength)
            && fits(applicationName, Self.maximumLabelLength)
            && fits(applicationBundleID, Self.maximumLabelLength)
    }

    public func with(delivery: DictationRecordDelivery) -> Self {
        Self(
            id: id, createdAt: createdAt, duration: duration, text: text, originalText: originalText,
            mode: mode, language: language, engine: engine, applicationName: applicationName,
            applicationBundleID: applicationBundleID, delivery: delivery)
    }
}

/// The persisted consent for the history. `generation` advances whenever
/// saving is turned off or everything is deleted, so a dictation admitted
/// before that change can no longer be written.
public struct DictationHistoryPolicy: Equatable, Sendable {
    public static let retentionChoices = [7, 30, 90]
    public static let off = Self(isEnabled: false, keepsOriginal: false, retentionDays: 30, generation: 0)

    public let isEnabled: Bool
    public let keepsOriginal: Bool
    public let retentionDays: Int
    public let generation: Int
    /// Local agents may read the history through the MCP server.
    public let exposesToAgents: Bool

    public init(
        isEnabled: Bool, keepsOriginal: Bool, retentionDays: Int, generation: Int, exposesToAgents: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.keepsOriginal = keepsOriginal
        self.retentionDays = retentionDays
        self.generation = generation
        self.exposesToAgents = exposesToAgents
    }

    /// Agents read only while the history itself is on.
    public var agentsCanRead: Bool { isEnabled && exposesToAgents }
}

public enum DictationRecordOutcome: Equatable, Sendable {
    case saved
    /// History was off, or its consent changed after the dictation started.
    case refused
}

/// What the history list shows. Every filter applies before the page limit.
public struct DictationRecordFilter: Equatable, Sendable {
    public static let all = Self()
    public static let maximumQueryLength = 200
    public static let maximumQueryTerms = 16

    public var query: String
    public var applicationName: String?
    public var onlyNotDelivered: Bool

    public init(query: String = "", applicationName: String? = nil, onlyNotDelivered: Bool = false) {
        self.query = query
        self.applicationName = applicationName
        self.onlyNotDelivered = onlyNotDelivered
    }

    public var isUnfiltered: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && applicationName == nil && !onlyNotDelivered
    }
}

/// One page of the history, newest first, with the total that matched.
public struct DictationRecordPage: Equatable, Sendable {
    public let total: Int
    public let offset: Int
    public let records: [DictationRecord]

    public init(total: Int, offset: Int, records: [DictationRecord]) {
        self.total = total
        self.offset = offset
        self.records = records
    }
}

/// A read made for a local agent; consent is checked in the same read.
public enum DictationAgentRead<Value: Equatable & Sendable>: Equatable, Sendable {
    case notAllowed
    case allowed(Value)
}

/// A finished meeting a dictation can be added to as a note.
public struct DictationMeetingChoice: Equatable, Identifiable, Sendable {
    public let id: MeetingID
    public let title: String
    public let startedAt: Date
    /// The dictation was made while this meeting was being recorded.
    public let containsDictation: Bool

    public init(id: MeetingID, title: String, startedAt: Date, containsDictation: Bool) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.containsDictation = containsDictation
    }
}

/// A meeting whose notes hold a copy of a dictation.
public struct DictationMeetingLink: Equatable, Sendable {
    public let meetingID: MeetingID
    public let title: String

    public init(meetingID: MeetingID, title: String) {
        self.meetingID = meetingID
        self.title = title
    }
}

public enum AddDictationToMeetingOutcome: Equatable, Sendable {
    /// `tidiedNotes`: the meeting shows tidied notes, which hide raw notes until tidied again.
    case added(noteID: UUID, tidiedNotes: Bool)
    case alreadyAdded
    case dictationMissing
    /// The meeting is deleted, unknown or still recording.
    case meetingUnavailable
}
