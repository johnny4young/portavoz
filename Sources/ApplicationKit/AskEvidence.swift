import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

/// The library reads behind an answer's evidence rows.
public protocol AskEvidenceReading: Sendable {
    func askCitedLines(_ lines: [MeetingID: [UUID]]) async throws -> [MeetingID: AskCitedLines]
    func voiceColumns(for meetingIDs: [MeetingID]) async throws -> [MeetingID: MeetingVoiceColumns]
}

extension MeetingStore: AskEvidenceReading {}

/// "Who said it": one row per citation, led by the voice that said it and
/// placed on its meeting's voice strip.
public struct AskEvidence: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        /// The `[n]` marker the answer uses for this citation.
        public let number: Int
        public let citation: AskCitation
        /// Who said it; `identity == .me` is you.
        public let voice: VoiceStripSource.Voice?
        public let meetingStartedAt: Date?
        /// Where the moment sits on its meeting's strip, from 0 to 1.
        public let position: Double?
        public let isCitedByAnswer: Bool

        public var id: Int { number }
    }

    public struct Strip: Sendable, Equatable {
        public let meetingID: MeetingID
        public let source: VoiceStripSource
    }

    public let rows: [Row]
    /// Cited meetings' strips in first-cited order, as `TodayPageCast(meetings:)` takes them.
    public let strips: [Strip]

    public static let empty = Self(rows: [], strips: [])

    public var meetingCount: Int { Set(rows.map(\.citation.meetingID)).count }
    public var voiceCount: Int { Set(rows.compactMap(\.voice?.key)).count }
}

/// Builds the evidence rows for an answer's citations. Rows keep citation
/// order, so row `n` is the passage the answer cites as `[n]`.
public struct LoadAskEvidence: Sendable {
    private let reader: any AskEvidenceReading

    public init(reader: any AskEvidenceReading) {
        self.reader = reader
    }

    public func callAsFunction(
        citations: [AskCitation],
        answer: String?
    ) async throws -> AskEvidence {
        guard !citations.isEmpty else { return .empty }
        var order: [MeetingID] = []
        var lines: [MeetingID: [UUID]] = [:]
        for citation in citations {
            if lines[citation.meetingID] == nil { order.append(citation.meetingID) }
            lines[citation.meetingID, default: []] += Self.lineIDs(of: citation)
        }
        async let attributedRead = reader.askCitedLines(lines)
        async let columnsRead = reader.voiceColumns(for: order)
        let (attributed, columns) = try await (attributedRead, columnsRead)
        try Task.checkCancellation()
        let sources = columns.mapValues(VoiceStripSource.init(columns:))
        let cited = Set(answer.map {
            CompanionAnswer.citedPassageIndexes($0, passageCount: citations.count)
        } ?? [])
        let rows = citations.enumerated().map { index, citation in
            let meeting = attributed[citation.meetingID]
            let source = sources[citation.meetingID]
            let speaker = meeting.flatMap { Self.speaker(of: citation, in: $0) }
            return AskEvidence.Row(
                number: index + 1,
                citation: citation,
                voice: speaker.flatMap { speaker in source?.voices.first { $0.speakerID == speaker } },
                meetingStartedAt: meeting?.startedAt,
                position: source.flatMap { Self.position(of: citation.timestamp, in: $0.duration) },
                isCitedByAnswer: cited.contains(index))
        }
        return AskEvidence(
            rows: rows,
            strips: order.compactMap { id in
                sources[id].map { AskEvidence.Strip(meetingID: id, source: $0) }
            })
    }

    /// The visible line first, then the accepted segments behind it.
    private static func lineIDs(of citation: AskCitation) -> [UUID] {
        (citation.segmentID.map { [$0] } ?? []) + citation.sourceSegmentIDs
    }

    /// A split part nobody is heard saying stays unattributed.
    private static func speaker(of citation: AskCitation, in meeting: AskCitedLines) -> SpeakerID? {
        for id in lineIDs(of: citation) {
            if let speaker = meeting.speakers[id] { return speaker }
            if meeting.unattributedParts.contains(id) { return nil }
        }
        return nil
    }

    private static func position(of time: TimeInterval, in duration: TimeInterval) -> Double? {
        guard time.isFinite, duration.isFinite, duration > 0 else { return nil }
        return min(1, max(0, time / duration))
    }
}
