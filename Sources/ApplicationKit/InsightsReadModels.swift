import Foundation
import PortavozCore

/// One confirmed participant in the library-wide Insights facts projection.
public struct InsightsParticipant: Sendable, Equatable, Identifiable {
    public let name: String
    public let meetings: Int
    public var id: String { name }

    public init(name: String, meetings: Int) {
        self.name = name
        self.meetings = meetings
    }
}

/// People and commitment facts shaped for the Insights dashboard.
public struct InsightsLibraryFacts: Sendable, Equatable {
    public let topParticipants: [InsightsParticipant]
    public let openActionItems: Int
    public let doneActionItems: Int

    public init(
        topParticipants: [InsightsParticipant],
        openActionItems: Int,
        doneActionItems: Int
    ) {
        self.topParticipants = topParticipants
        self.openActionItems = openActionItems
        self.doneActionItems = doneActionItems
    }
}

/// Talk-time relationship with one confirmed participant.
public struct InsightsParticipantVoice: Sendable, Equatable, Identifiable {
    public let name: String
    public let meetings: Int
    public let theirSeconds: TimeInterval
    public let myShareWithThem: Double
    public var id: String { name }

    public init(
        name: String,
        meetings: Int,
        theirSeconds: TimeInterval,
        myShareWithThem: Double
    ) {
        self.name = name
        self.meetings = meetings
        self.theirSeconds = theirSeconds
        self.myShareWithThem = myShareWithThem
    }
}

/// Library-wide talk balance shaped independently from persistence records.
public struct InsightsVoiceBalance: Sendable, Equatable {
    public let participants: [InsightsParticipantVoice]
    public let myOverallShare: Double
    public let hasData: Bool

    public init(
        participants: [InsightsParticipantVoice],
        myOverallShare: Double,
        hasData: Bool
    ) {
        self.participants = participants
        self.myOverallShare = myOverallShare
        self.hasData = hasData
    }
}

/// Stored evidence needed to derive local findings for one meeting.
public struct InsightsFindingInput: Sendable, Equatable {
    public let transcript: String
    public let summaryMarkdown: String?
    public let actionItemCount: Int

    public init(transcript: String, summaryMarkdown: String?, actionItemCount: Int) {
        self.transcript = transcript
        self.summaryMarkdown = summaryMarkdown
        self.actionItemCount = actionItemCount
    }
}

/// The complete storage-independent projection rendered by Insights.
/// Persistence adapters supply raw facts; deterministic application policy
/// owns scope, totals, decision evidence, and participant/topic exclusions.
public struct InsightsReadModel: Sendable {
    public let meetings: [Meeting]
    public let stats: LibraryStats
    public let totals: ScopedTotals
    public let facts: InsightsLibraryFacts?
    public let balance: InsightsVoiceBalance?
    public let noDecision: InsightsFindings.NoDecision?
    public let topics: [InsightsFindings.RecurringTopic]

    public static func compute(
        meetings: [Meeting],
        facts: InsightsLibraryFacts?,
        balance: InsightsVoiceBalance?,
        findingInputs: [MeetingID: InsightsFindingInput],
        scope: InsightsScope,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> InsightsReadModel {
        let interval = scope.currentInterval(now: now, calendar: calendar)
        let scoped = meetings
            .filter { interval.contains($0.startedAt) }
            .prefix(60)
        let findingFacts = scoped.map { meeting -> InsightsFindings.MeetingFact in
            let input = findingInputs[meeting.id]
            let seconds = meeting.endedAt.map {
                $0.timeIntervalSince(meeting.startedAt)
            } ?? 0
            let hasDecision = (input?.actionItemCount ?? 0) > 0
                || markdownHasDecision(input?.summaryMarkdown)
            return InsightsFindings.MeetingFact(
                id: meeting.id,
                startedAt: meeting.startedAt,
                seconds: max(0, seconds),
                hasSummary: input?.summaryMarkdown != nil,
                hasDecision: hasDecision,
                transcript: input?.transcript ?? "")
        }
        let exclusions = participantNames(facts: facts, balance: balance)
        return InsightsReadModel(
            meetings: meetings,
            stats: LibraryStats.compute(
                meetings: meetings,
                calendar: calendar,
                now: now),
            totals: ScopedTotals.compute(
                meetings: meetings,
                scope: scope,
                now: now,
                calendar: calendar),
            facts: facts,
            balance: balance,
            noDecision: InsightsFindings.noDecision(Array(findingFacts)),
            topics: InsightsFindings.recurringTopics(
                Array(findingFacts),
                exclude: exclusions))
    }
}

/// Independently observed Insights query families. Writes wake only the
/// projections whose explicit StorageKit regions include the changed table.
public enum InsightsSection: CaseIterable, Hashable, Sendable {
    case meetings
    case facts
    case voiceBalance
    case findings
}

/// Query-scoped raw updates reduced into one `InsightsReadModel` by the
/// per-window feature model.
public enum InsightsUpdate: Sendable {
    case meetings([Meeting])
    case facts(InsightsLibraryFacts)
    case voiceBalance(InsightsVoiceBalance)
    case findingInputs([MeetingID: InsightsFindingInput])
    case failed(InsightsSection)
}

/// Language-dependent tokens for the content-free Insights heuristics, in one
/// place on purpose: the product ships bilingual EN+ES summaries (D34), and
/// supporting another UI language extends these lists here instead of hunting
/// string literals across the reducer.
private enum InsightsLexicon {
    /// Self-referential speaker labels excluded from recurring-topic
    /// candidates ("me" EN, "yo" ES).
    static let selfNames: Set<String> = ["me", "yo"]
    /// Lowercased heading fragment shared by the English and Spanish words
    /// for decision(s), so one probe covers both catalog languages.
    static let decisionHeadingFragment = "decis"
}

private extension InsightsReadModel {
    static func participantNames(
        facts: InsightsLibraryFacts?,
        balance: InsightsVoiceBalance?
    ) -> Set<String> {
        var names = InsightsLexicon.selfNames
        for person in balance?.participants ?? [] {
            names.insert(person.name.lowercased())
        }
        for person in facts?.topParticipants ?? [] {
            names.insert(person.name.lowercased())
        }
        return names
    }

    static func markdownHasDecision(_ markdown: String?) -> Bool {
        guard let markdown else { return false }
        return SummarySections.parse(markdown).sections.contains { section in
            section.bulletCount > 0
                && section.heading.lowercased()
                    .contains(InsightsLexicon.decisionHeadingFragment)
        }
    }
}
