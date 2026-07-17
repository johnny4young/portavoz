import Foundation
import PortavozCore

/// The `.portavoz` interchange file (M15 L0): one meeting — transcript,
/// cast, latest summary, co-authoring notes, and Companion cards — as one
/// versioned JSON document another Mac can import. Audio is OPTIONAL (an additive field,
/// so no version bump: readers without it import the text and ignore the
/// audio) — a text-only file stays mail-sized, a with-audio file carries
/// the recording itself. The format is additive: readers accept any file
/// whose `formatVersion` they know, and unknown FUTURE fields are ignored
/// by Codable.
public struct MeetingBundle: Codable, Sendable {
    public static let currentFormatVersion = 1
    public static let fileExtension = "portavoz"
    /// Exported UTI (declared in the app's Info.plist).
    public static let typeIdentifier = "app.portavoz.meeting-bundle"

    public var formatVersion: Int
    public var exportedAt: Date
    public var meeting: Meeting
    public var speakers: [Speaker]
    public var segments: [TranscriptSegment]
    public var summary: SummaryDraft?
    public var contextItems: [ContextItem]
    /// Saved Companion answers/pings. Optional so bundles written before the
    /// field existed keep decoding as format v1; nil and empty are equivalent.
    public var companionCards: [CompanionCard]?
    /// Optional recording channels ("system"/"microphone"); `Data` rides
    /// as base64 via Codable's default strategy. Additive: absent in
    /// text-only exports, ignored by readers that predate it.
    public var audioFiles: [AudioAttachment]?

    public struct AudioAttachment: Codable, Sendable {
        /// Channel name without extension ("system", "microphone").
        public let name: String
        public let fileExtension: String
        public let data: Data

        public init(name: String, fileExtension: String, data: Data) {
            self.name = name
            self.fileExtension = fileExtension
            self.data = data
        }
    }

    public init(
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        summary: SummaryDraft? = nil,
        contextItems: [ContextItem] = [],
        companionCards: [CompanionCard] = [],
        audioFiles: [AudioAttachment]? = nil,
        exportedAt: Date = Date()
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        var shared = meeting
        // Paths are machine-local (D4); optional audio travels as attachments.
        shared.audioDirectory = nil
        self.meeting = shared
        // Canonical people are private library memory, not interchange data.
        // Keep the meeting-local name while stripping every cross-meeting link.
        self.speakers = speakers.map { speaker in
            Speaker(
                id: speaker.id,
                meetingID: speaker.meetingID,
                label: speaker.label,
                displayName: speaker.displayName,
                isMe: speaker.isMe,
                personID: nil)
        }
        self.segments = segments
        self.summary = summary
        self.contextItems = contextItems
        self.companionCards = companionCards.isEmpty ? nil : companionCards
        self.audioFiles = audioFiles
    }

    public enum BundleError: Error, LocalizedError, Equatable {
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "this .portavoz file uses format v\(version) — update Portavoz to open it"
            }
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> MeetingBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(MeetingBundle.self, from: data)
        guard bundle.formatVersion <= currentFormatVersion else {
            throw BundleError.unsupportedVersion(bundle.formatVersion)
        }
        return bundle
    }

    /// A copy with FRESH identifiers throughout (meeting, speakers,
    /// segments, action items, notes, Companion cards) with every relation
    /// preserved — importing can never collide with existing rows, and
    /// importing the same file twice yields two independent meetings.
    public func remappedForImport() -> MeetingBundle {
        var copy = self
        let newMeetingID = MeetingID()
        var speakerMap: [SpeakerID: SpeakerID] = [:]
        var segmentMap: [UUID: UUID] = [:]

        copy.meeting.id = newMeetingID
        copy.speakers = speakers.map { speaker in
            let newID = SpeakerID()
            speakerMap[speaker.id] = newID
            return Speaker(
                id: newID,
                meetingID: newMeetingID,
                label: speaker.label,
                displayName: speaker.displayName,
                isMe: speaker.isMe,
                personID: nil)
        }
        copy.segments = segments.map { segment in
            let newID = UUID()
            segmentMap[segment.id] = newID
            return TranscriptSegment(
                id: newID,
                meetingID: newMeetingID,
                speakerID: segment.speakerID.flatMap { speakerMap[$0] },
                channel: segment.channel,
                text: segment.text,
                language: segment.language,
                startTime: segment.startTime,
                endTime: segment.endTime,
                confidence: segment.confidence,
                isFinal: segment.isFinal)
        }
        copy.summary = remappedSummary(
            meetingID: newMeetingID,
            speakerMap: speakerMap,
            segmentMap: segmentMap)
        copy.contextItems = contextItems.map { item in
            ContextItem(
                id: UUID(),
                meetingID: newMeetingID,
                kind: item.kind,
                content: item.content,
                timestamp: item.timestamp)
        }
        copy.companionCards = companionCards?.map { card in
            CompanionCard(
                id: UUID(), question: card.question, answer: card.answer,
                kind: card.kind, source: card.source, directed: card.directed,
                askedAt: card.askedAt)
        }
        return copy
    }

    private func remappedSummary(
        meetingID: MeetingID,
        speakerMap: [SpeakerID: SpeakerID],
        segmentMap: [UUID: UUID]
    ) -> SummaryDraft? {
        guard let summary else { return nil }
        return SummaryDraft(
            meetingID: meetingID,
            recipeID: summary.recipeID,
            language: summary.language,
            markdown: summary.markdown,
            actionItems: summary.actionItems.map { item in
                ActionItem(
                    id: UUID(),
                    text: item.text,
                    ownerSpeakerID: item.ownerSpeakerID.flatMap { speakerMap[$0] },
                    isDone: item.isDone)
            },
            fingerprint: summary.fingerprint,
            claims: summary.claims.compactMap { claim in
                let evidenceIDs = claim.evidenceSegmentIDs.compactMap { segmentMap[$0] }
                guard evidenceIDs.count == claim.evidenceSegmentIDs.count,
                      claim.unavailableEvidenceCount == 0
                else { return nil }
                return SummaryClaim(
                    kind: claim.kind,
                    sourceTranscriptRevision: nil,
                    evidenceSegmentIDs: evidenceIDs,
                    feedback: claim.feedback)
            },
            decisionEvidence: summary.decisionEvidence.compactMap { decision in
                let evidenceIDs = decision.evidenceSegmentIDs.compactMap { segmentMap[$0] }
                guard evidenceIDs.count == decision.evidenceSegmentIDs.count,
                      decision.unavailableEvidenceCount == 0
                else { return nil }
                return SummaryDecisionEvidence(
                    sectionOrdinal: decision.sectionOrdinal,
                    bulletOrdinal: decision.bulletOrdinal,
                    sourceTranscriptRevision: nil,
                    evidenceSegmentIDs: evidenceIDs)
            })
    }
}
