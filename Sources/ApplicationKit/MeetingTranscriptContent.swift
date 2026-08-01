import Foundation
import PortavozCore

/// The immutable machine transcript under a reading projection.
///
/// `unspecified` keeps legacy callers honest until storage exposes accepted
/// transcript provenance. Correction composition requires callers to choose
/// `raw` or `refined` explicitly.
public enum MeetingTranscriptBaseMaterial: String, Sendable, Equatable {
    case unspecified
    case raw
    case refined
}

/// The explicit reading selected over immutable transcript material.
public enum MeetingTranscriptProjection: String, Sendable, Equatable {
    case accepted
    case composed
}

/// Provenance for the rows currently presented to a transcript consumer.
public struct MeetingTranscriptLineage: Sendable, Equatable {
    public let baseMaterial: MeetingTranscriptBaseMaterial
    public let projection: MeetingTranscriptProjection
    public let activeCorrectionIDs: [UUID]

    public init(
        baseMaterial: MeetingTranscriptBaseMaterial,
        projection: MeetingTranscriptProjection = .accepted,
        activeCorrectionIDs: [UUID] = []
    ) {
        self.baseMaterial = baseMaterial
        self.projection = projection
        self.activeCorrectionIDs = activeCorrectionIDs
    }

    public var isComposed: Bool { projection == .composed }
}

/// The transcript value consumed by review presentation.
///
/// `accepted` projects the stored transcript one row per source segment.
/// `ComposeTranscript` can build the same value with split or merged rows while
/// retaining `sourceSegmentIDs`; SwiftUI therefore never needs to decide
/// whether text is raw, refined, or composed.
public struct MeetingTranscriptContent: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let sourceSegmentIDs: [UUID]
        public let speakerID: SpeakerID?
        public let channel: AudioChannel
        public let text: String
        public let language: String?
        public let startTime: TimeInterval
        public let endTime: TimeInterval
        public let confidence: Double?
        public let isFinal: Bool

        public init(
            id: UUID,
            sourceSegmentIDs: [UUID],
            speakerID: SpeakerID?,
            channel: AudioChannel,
            text: String,
            language: String?,
            startTime: TimeInterval,
            endTime: TimeInterval,
            confidence: Double?,
            isFinal: Bool
        ) {
            self.id = id
            self.sourceSegmentIDs = sourceSegmentIDs
            self.speakerID = speakerID
            self.channel = channel
            self.text = text
            self.language = language
            self.startTime = startTime
            self.endTime = endTime
            self.confidence = confidence
            self.isFinal = isFinal
        }
    }

    public struct Chapter: Sendable, Equatable, Identifiable {
        public let startTime: TimeInterval
        public let title: String

        public init(startTime: TimeInterval, title: String) {
            self.startTime = startTime
            self.title = title
        }

        public var id: TimeInterval { startTime }
    }

    public let baseTranscriptRevision: Int
    public let rows: [Row]
    public let chapters: [Chapter]
    public let lineage: MeetingTranscriptLineage

    private let sourceRowIDs: [UUID: UUID]
    private let maximumEndTree: [TimeInterval]
    private let maximumEndTreeLeafCount: Int

    public init(
        baseTranscriptRevision: Int,
        rows: [Row],
        chapters: [Chapter],
        lineage: MeetingTranscriptLineage = MeetingTranscriptLineage(
            baseMaterial: .unspecified)
    ) {
        self.baseTranscriptRevision = baseTranscriptRevision
        self.rows = rows.sorted(by: Self.rowPrecedes)
        self.chapters = chapters.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.title < $1.title
        }
        self.lineage = lineage

        var sourceRowIDs: [UUID: UUID] = [:]
        for row in self.rows {
            for sourceID in row.sourceSegmentIDs where sourceRowIDs[sourceID] == nil {
                sourceRowIDs[sourceID] = row.id
            }
        }
        self.sourceRowIDs = sourceRowIDs

        var leafCount = 1
        while leafCount < self.rows.count { leafCount *= 2 }
        var maximumEndTree = Array(
            repeating: -TimeInterval.infinity,
            count: leafCount * 2)
        for (index, row) in self.rows.enumerated() {
            maximumEndTree[leafCount + index] = row.endTime
        }
        if leafCount > 1 {
            for index in stride(from: leafCount - 1, through: 1, by: -1) {
                maximumEndTree[index] = max(
                    maximumEndTree[index * 2],
                    maximumEndTree[index * 2 + 1])
            }
        }
        self.maximumEndTree = maximumEndTree
        self.maximumEndTreeLeafCount = leafCount
    }

    public static func accepted(
        baseTranscriptRevision: Int,
        segments: [TranscriptSegment],
        chapterTitles: [TimeInterval: String],
        baseMaterial: MeetingTranscriptBaseMaterial = .unspecified
    ) -> MeetingTranscriptContent {
        let rows = segments.map { segment in
            Row(
                id: segment.id,
                sourceSegmentIDs: [segment.id],
                speakerID: segment.speakerID,
                channel: segment.channel,
                text: segment.text,
                language: segment.language,
                startTime: segment.startTime,
                endTime: segment.endTime,
                confidence: segment.confidence,
                isFinal: segment.isFinal)
        }
        let chapters = ChapterExtractor.chapters(from: segments).map { chapter in
            Chapter(
                startTime: chapter.startTime,
                title: chapterTitles[chapter.startTime] ?? chapter.title)
        }
        return MeetingTranscriptContent(
            baseTranscriptRevision: baseTranscriptRevision,
            rows: rows,
            chapters: chapters,
            lineage: MeetingTranscriptLineage(baseMaterial: baseMaterial))
    }

    /// Resolves persisted evidence coordinates to the row currently shown.
    /// Split and merged correction rows can therefore keep pointing back to
    /// immutable accepted segments without presentation knowing the policy.
    public func rowID(containingSourceSegmentID sourceSegmentID: UUID) -> UUID? {
        sourceRowIDs[sourceSegmentID]
    }

    /// Resolves a timestamp-only route (Library, Ask, Spotlight) to the row
    /// currently shown. Before the first turn it selects the first row; gaps
    /// and timestamps after speech retain the last row that had started.
    public func rowID(at timestamp: TimeInterval) -> UUID? {
        activeRowID(at: timestamp) ?? rows.first?.id
    }

    /// Finds the row under the playhead without scanning the whole transcript
    /// on each 200 ms playback update. In a gap, the last started row remains
    /// active, matching the released reading behavior.
    public func activeRowID(at time: TimeInterval) -> UUID? {
        guard !rows.isEmpty else { return nil }

        var lower = 0
        var upper = rows.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if rows[middle].startTime <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return nil }

        let fallback = rows[lower - 1].id
        guard let activeIndex = rightmostRowEnding(after: time, upperBound: lower) else {
            return fallback
        }
        return rows[activeIndex].id
    }

    /// Segment-tree lookup for the rightmost already-started row whose end is
    /// still ahead of the playhead. This preserves overlapping-row behavior
    /// without making a long overlap chain degrade the playback refresh path.
    private func rightmostRowEnding(
        after time: TimeInterval,
        upperBound: Int
    ) -> Int? {
        func search(node: Int, lower: Int, upper: Int) -> Int? {
            guard lower < upperBound, maximumEndTree[node] > time else { return nil }
            if upper - lower == 1 {
                return lower < rows.count ? lower : nil
            }
            let middle = lower + (upper - lower) / 2
            if let right = search(
                node: node * 2 + 1,
                lower: middle,
                upper: upper) {
                return right
            }
            return search(node: node * 2, lower: lower, upper: middle)
        }

        return search(node: 1, lower: 0, upper: maximumEndTreeLeafCount)
    }

    private static func rowPrecedes(_ lhs: Row, _ rhs: Row) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        if lhs.endTime != rhs.endTime { return lhs.endTime < rhs.endTime }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// Small value state for cross-section evidence navigation. It stores no
/// player, model, or service and can later resolve accepted evidence into a
/// correction-composed row through `MeetingTranscriptContent`.
public struct MeetingTranscriptNavigationState: Sendable, Equatable {
    public private(set) var focusedRowID: UUID?
    public private(set) var pendingSeek: TimeInterval?

    public init(focusedRowID: UUID? = nil, pendingSeek: TimeInterval? = nil) {
        self.focusedRowID = focusedRowID
        self.pendingSeek = pendingSeek
    }

    public mutating func reveal(
        sourceSegmentID: UUID,
        at timestamp: TimeInterval,
        in content: MeetingTranscriptContent
    ) {
        focusedRowID = content.rowID(containingSourceSegmentID: sourceSegmentID)
        pendingSeek = max(0, timestamp)
    }

    public mutating func requestSeek(
        to timestamp: TimeInterval,
        in content: MeetingTranscriptContent
    ) {
        let timestamp = max(0, timestamp)
        focusedRowID = content.rowID(at: timestamp)
        pendingSeek = timestamp
    }

    public mutating func consumePendingSeek() -> TimeInterval? {
        defer { pendingSeek = nil }
        return pendingSeek
    }
}
