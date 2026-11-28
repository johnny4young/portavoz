import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

/// The library reads behind an answer's evidence rows.
public protocol AskEvidenceReading: MeetingVoiceAttributionReading {
    func askOpenCommitments(segmentIDs: Set<UUID>) async throws -> [CommitmentID]
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
    /// Open commitments whose evidence is one of the cited lines.
    public let openCommitments: [CommitmentID]

    init(rows: [Row], strips: [Strip], openCommitments: [CommitmentID] = []) {
        self.rows = rows
        self.strips = strips
        self.openCommitments = openCommitments
    }

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
        let segmentIDs = Set(lines.values.joined())
        async let attributedRead = reader.askCitedLines(lines)
        async let columnsRead = reader.voiceColumns(for: order)
        // Best effort: a failed commitment read must not drop the voices.
        async let commitmentsRead = try? reader.askOpenCommitments(segmentIDs: segmentIDs)
        let (attributed, columns, commitments) = try await (attributedRead, columnsRead, commitmentsRead)
        try Task.checkCancellation()
        let sources = columns.mapValues(VoiceStripSource.init(columns:))
        let cited = Set(answer.map {
            CompanionAnswer.citedPassageIndexes($0, passageCount: citations.count)
        } ?? [])
        let rows = citations.enumerated().map { index, citation in
            let meeting = attributed[citation.meetingID]
            let source = sources[citation.meetingID]
            let speaker = meeting.flatMap { $0.speaker(of: Self.lineIDs(of: citation)) }
            return AskEvidence.Row(
                number: index + 1,
                citation: citation,
                voice: source?.voice(speaker),
                meetingStartedAt: meeting?.startedAt,
                position: source.flatMap { $0.position(of: citation.timestamp) },
                isCitedByAnswer: cited.contains(index))
        }
        return AskEvidence(
            rows: rows,
            strips: order.compactMap { id in
                sources[id].map { AskEvidence.Strip(meetingID: id, source: $0) }
            },
            openCommitments: commitments ?? [])
    }

    /// The visible line first, then the accepted segments behind it.
    private static func lineIDs(of citation: AskCitation) -> [UUID] {
        (citation.segmentID.map { [$0] } ?? []) + citation.sourceSegmentIDs
    }

}

extension AskCitedLines {
    /// The first of these lines someone is heard saying; a split part nobody
    /// is heard saying stays unattributed rather than borrowing the next line's voice.
    func speaker(of ids: [UUID]) -> SpeakerID? {
        for id in ids {
            if let speaker = speakers[id] { return speaker }
            if unattributedParts.contains(id) { return nil }
        }
        return nil
    }
}

extension VoiceStripSource {
    /// Where a moment sits on the strip, from 0 to 1.
    func position(of time: TimeInterval) -> Double? {
        guard time.isFinite, duration.isFinite, duration > 0 else { return nil }
        return min(1, max(0, time / duration))
    }

    func voice(_ speaker: SpeakerID?) -> Voice? {
        speaker.flatMap { speaker in voices.first { $0.speakerID == speaker } }
    }
}
