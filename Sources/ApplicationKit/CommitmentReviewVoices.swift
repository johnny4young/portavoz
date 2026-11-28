import Foundation
import PortavozCore
import StorageKit

/// The two library reads that attribute transcript lines to voices.
public protocol MeetingVoiceAttributionReading: Sendable {
    func askCitedLines(_ lines: [MeetingID: [UUID]]) async throws -> [MeetingID: AskCitedLines]
    func voiceColumns(for meetingIDs: [MeetingID]) async throws -> [MeetingID: MeetingVoiceColumns]
}

extension MeetingStore: MeetingVoiceAttributionReading {}

/// Who said each suggestion to review, and where its evidence sits on the
/// meeting's voice strip.
public struct CommitmentReviewVoices: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        /// The voice heard saying the first attributed evidence line.
        public let voice: VoiceStripSource.Voice?
        /// Each evidence moment on the strip, from 0 to 1, in transcript order.
        public let moments: [Double]

        public init(voice: VoiceStripSource.Voice?, moments: [Double]) {
            self.voice = voice
            self.moments = moments
        }
    }

    public struct Strip: Sendable, Equatable {
        public let meetingID: MeetingID
        public let source: VoiceStripSource

        public init(meetingID: MeetingID, source: VoiceStripSource) {
            self.meetingID = meetingID
            self.source = source
        }
    }

    public let items: [UUID: Item]
    /// Strips in first-listed order, as `TodayPageCast(meetings:)` takes them.
    public let strips: [Strip]

    public init(items: [UUID: Item], strips: [Strip]) {
        self.items = items
        self.strips = strips
    }

    public static let empty = Self(items: [:], strips: [])

    /// The meeting's people as owner choices, the suggested owner first.
    public func ownerChoices(
        for meetingID: MeetingID,
        suggested: CommitmentReviewQueueOwner?
    ) -> [CommitmentOwnerSuggestion] {
        let voices = strips.first { $0.meetingID == meetingID }?.source.voices ?? []
        let people = voices.compactMap { voice -> CommitmentOwnerSuggestion? in
            guard case .person(let personID) = voice.identity else { return nil }
            return CommitmentOwnerSuggestion(personID: personID, displayName: voice.name ?? voice.label)
        }
        var seen: Set<PersonID> = []
        return ([suggested?.suggestion].compactMap { $0 } + people).filter { seen.insert($0.personID).inserted }
    }

    /// These voices with `newer` read on top, keeping only `items`.
    public func merging(_ newer: Self, keeping items: [CommitmentReviewQueueItem]) -> Self {
        let ids = Set(items.map(\.id))
        let meetings = Set(items.map(\.meetingID))
        var strips = strips.filter { meetings.contains($0.meetingID) }
        for strip in newer.strips where !strips.contains(where: { $0.meetingID == strip.meetingID }) {
            strips.append(strip)
        }
        return Self(
            items: self.items.merging(newer.items) { _, new in new }.filter { ids.contains($0.key) },
            strips: strips)
    }
}

/// Attributes a review page's evidence with the same corrected transcript the
/// voice strip draws. Stale or unavailable evidence has no lines to place.
public struct LoadCommitmentReviewVoices: Sendable {
    private let reader: any MeetingVoiceAttributionReading

    public init(reader: any MeetingVoiceAttributionReading) {
        self.reader = reader
    }

    public func callAsFunction(
        _ items: [CommitmentReviewQueueItem]
    ) async throws -> CommitmentReviewVoices {
        guard !items.isEmpty else { return .empty }
        var order: [MeetingID] = []
        var lines: [MeetingID: [UUID]] = [:]
        for item in items {
            if lines[item.meetingID] == nil { order.append(item.meetingID) }
            lines[item.meetingID, default: []] += item.currentEvidence.map(\.id)
        }
        async let attributedRead = reader.askCitedLines(lines.filter { !$0.value.isEmpty })
        async let columnsRead = reader.voiceColumns(for: order)
        let (attributed, columns) = try await (attributedRead, columnsRead)
        try Task.checkCancellation()
        let sources = columns.mapValues(VoiceStripSource.init(columns:))
        var result: [UUID: CommitmentReviewVoices.Item] = [:]
        for item in items {
            let segments = item.currentEvidence
            let source = sources[item.meetingID]
            result[item.id] = CommitmentReviewVoices.Item(
                voice: source?.voice(attributed[item.meetingID]?.speaker(of: segments.map(\.id))),
                moments: source.map { source in segments.compactMap { source.position(of: $0.startTime) } } ?? [])
        }
        return CommitmentReviewVoices(
            items: result,
            strips: order.compactMap { id in
                sources[id].map { CommitmentReviewVoices.Strip(meetingID: id, source: $0) }
            })
    }
}

public extension CommitmentReviewQueueOwner {
    var suggestion: CommitmentOwnerSuggestion {
        CommitmentOwnerSuggestion(personID: personID, displayName: displayName)
    }
}
