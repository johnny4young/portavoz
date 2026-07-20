import Foundation
import PortavozCore

/// Storage- and model-independent material shown before an upcoming meeting.
public struct MeetingBrief: Sendable {
    public let event: UpcomingEvent
    public let related: [RelatedMeeting]
    public let openItems: [OpenItem]
    public let whatToKnow: [KnowPoint]

    public init(
        event: UpcomingEvent,
        related: [RelatedMeeting],
        openItems: [OpenItem],
        whatToKnow: [KnowPoint]
    ) {
        self.event = event
        self.related = related
        self.openItems = openItems
        self.whatToKnow = whatToKnow
    }

    public struct RelatedMeeting: Identifiable, Equatable, Sendable {
        public var id: MeetingID { meetingID }
        public let meetingID: MeetingID
        public let title: String
        public let overview: String
        public let matchedTerms: [String]
        public let snippet: String

        public init(
            meetingID: MeetingID,
            title: String,
            overview: String,
            matchedTerms: [String],
            snippet: String
        ) {
            self.meetingID = meetingID
            self.title = title
            self.overview = overview
            self.matchedTerms = matchedTerms
            self.snippet = snippet
        }
    }

    public struct OpenItem: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let meetingID: MeetingID
        public let meetingTitle: String
        public let text: String

        public init(
            id: UUID,
            meetingID: MeetingID,
            meetingTitle: String,
            text: String
        ) {
            self.id = id
            self.meetingID = meetingID
            self.meetingTitle = meetingTitle
            self.text = text
        }
    }

    public struct SynthesisSource: Equatable, Sendable {
        public let meetingID: MeetingID
        public let meetingTitle: String
        public let overview: String

        public init(
            meetingID: MeetingID,
            meetingTitle: String,
            overview: String
        ) {
            self.meetingID = meetingID
            self.meetingTitle = meetingTitle
            self.overview = overview
        }
    }

    public struct SynthesisPoint: Equatable, Sendable {
        public let text: String
        public let sourceIndex: Int

        public init(text: String, sourceIndex: Int) {
            self.text = text
            self.sourceIndex = sourceIndex
        }
    }

    public struct KnowPoint: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let text: String
        public let meetingID: MeetingID
        public let meetingTitle: String

        public init(
            id: UUID = UUID(),
            text: String,
            meetingID: MeetingID,
            meetingTitle: String
        ) {
            self.id = id
            self.text = text
            self.meetingID = meetingID
            self.meetingTitle = meetingTitle
        }
    }
}

public protocol MeetingBriefLibraryReading: Sendable {
    func meetingBriefSummaryMarkdowns(
        for meetingIDs: [MeetingID]
    ) async throws -> [MeetingID: String]
    func openMeetingBriefItems(limit: Int) async throws -> [MeetingBrief.OpenItem]
}

public protocol MeetingBriefSynthesizing: Sendable {
    func synthesizeMeetingBrief(
        eventTitle: String,
        sources: [MeetingBrief.SynthesisSource]
    ) async throws -> [MeetingBrief.SynthesisPoint]
}

/// Builds a degradable pre-meeting brief from shared Ask evidence, current
/// summaries, open commitments, and optional grounded synthesis.
public struct PrepareMeetingBrief: ApplicationUseCase {
    private let ask: AskMeetings
    private let library: any MeetingBriefLibraryReading
    private let synthesizer: any MeetingBriefSynthesizing

    public init(
        ask: AskMeetings,
        library: any MeetingBriefLibraryReading,
        synthesizer: any MeetingBriefSynthesizing
    ) {
        self.ask = ask
        self.library = library
        self.synthesizer = synthesizer
    }

    public func execute(_ event: UpcomingEvent) async throws -> MeetingBrief {
        let terms = BriefRelevance.terms(
            eventTitle: event.title,
            attendees: event.attendees)
        let query = ([event.title] + event.attendees).joined(separator: " ")
        let citations = try await degrade(to: []) {
            try await ask.evidence(query, limit: 12)
        }
        let ranked = BriefRelevance.rank(passages: citations, terms: terms)
        async let summaryMarkdowns = degrade(to: [MeetingID: String]()) {
            try await library.meetingBriefSummaryMarkdowns(
                for: ranked.map(\.meetingID))
        }
        async let pendingOpenItems = degrade(to: [MeetingBrief.OpenItem]()) {
            try await library.openMeetingBriefItems(limit: 50)
        }

        let summaries = try await summaryMarkdowns
        let related = ranked.compactMap { candidate -> MeetingBrief.RelatedMeeting? in
            guard let markdown = summaries[candidate.meetingID] else { return nil }
            return MeetingBrief.RelatedMeeting(
                meetingID: candidate.meetingID,
                title: candidate.title,
                overview: Self.overview(from: markdown),
                matchedTerms: candidate.matchedTerms,
                snippet: String(candidate.snippet.prefix(90)))
        }

        let relatedIDs = Set(related.map(\.meetingID))
        let allOpenItems = try await pendingOpenItems
        let openItems = Array(allOpenItems
            .filter { relatedIDs.contains($0.meetingID) }
            .prefix(8))

        let sources = related.map {
            MeetingBrief.SynthesisSource(
                meetingID: $0.meetingID,
                meetingTitle: $0.title,
                overview: $0.overview)
        }
        let synthesisPoints: [MeetingBrief.SynthesisPoint] = sources.isEmpty
            ? []
            : try await degrade(to: []) {
                try await synthesizer.synthesizeMeetingBrief(
                    eventTitle: event.title,
                    sources: sources)
            }
        let whatToKnow: [MeetingBrief.KnowPoint] = synthesisPoints.compactMap { point in
            guard sources.indices.contains(point.sourceIndex) else { return nil }
            let source = sources[point.sourceIndex]
            return MeetingBrief.KnowPoint(
                text: point.text,
                meetingID: source.meetingID,
                meetingTitle: source.meetingTitle)
        }

        return MeetingBrief(
            event: event,
            related: related,
            openItems: openItems,
            whatToKnow: whatToKnow)
    }

    private static func overview(from markdown: String) -> String {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first { !$0.hasPrefix("#") }
            .map(String.init) ?? ""
    }

    private func degrade<Value: Sendable>(
        to fallback: Value,
        operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return fallback
        }
    }
}
