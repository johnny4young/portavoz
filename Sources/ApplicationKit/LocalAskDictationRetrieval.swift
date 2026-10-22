import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

/// Local dictation adapter. The question's period and app become filters and
/// its remaining words a ranked any-word search. When the words miss within
/// the filters they are searched everywhere, since a weekday may be the topic;
/// when they still miss, or nothing is left to search, the newest dictations
/// within the filters are listed. The store checks the history consent in
/// each read, and only whole dictations within one prompt budget are cited.
public struct LocalAskDictationRetrieval: AskDictationRetrieving {
    static let candidateLimit = 24
    static let maximumQueryVariants = 3

    private let store: MeetingStore
    private let expander: BilingualSearchQueryExpander
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(
        store: MeetingStore,
        expander: BilingualSearchQueryExpander = .init(),
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.store = store
        self.expander = expander
        self.now = now
        self.calendar = calendar
    }

    public func retrieve(question: String, limit: Int) async throws -> AskDictationEvidence {
        guard let applications = try await store.dictationApplicationsForAsk() else { return .historyOff }
        let parsed = AskDictationQuestion.parse(
            question, applications: applications, now: now(), calendar: calendar)
        let filtered = parsed.period != nil || parsed.applicationName != nil
        var attempts: [(queries: [String], filtered: Bool)] = []
        if !parsed.isListing {
            let words = parsed.searchWords.joined(separator: " ")
            let queries = Array(expander.expand(words).prefix(Self.maximumQueryVariants))
            attempts.append((queries, true))
            if filtered { attempts.append((queries, false)) }
        }
        if parsed.isListing || filtered { attempts.append(([], true)) }
        for attempt in attempts {
            guard let records = try await store.dictationRecordsForAsk(
                matchingAny: attempt.queries,
                period: attempt.filtered ? parsed.period : nil,
                applicationName: attempt.filtered ? parsed.applicationName : nil,
                limit: Self.candidateLimit)
            else { return .historyOff }
            try Task.checkCancellation()
            guard !records.isEmpty else { continue }
            let citations = Self.select(records, limit: limit)
            return attempt.queries.isEmpty ? .listed(citations) : .found(citations)
        }
        return .found([])
    }

    static func select(_ records: [DictationRecord], limit: Int) -> [AskDictationCitation] {
        var characters = 0
        var bytes = 0
        var citations: [AskDictationCitation] = []
        for record in records where citations.count < limit {
            let text = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let nextCharacters = characters + text.count
            let nextBytes = bytes + text.utf8.count
            guard !text.isEmpty,
                  text.count <= AskDictationLimits.maximumCitationCharacters,
                  text.utf8.count <= AskDictationLimits.maximumCitationUTF8Bytes,
                  nextCharacters <= AskDictationLimits.maximumAggregateCharacters,
                  nextBytes <= AskDictationLimits.maximumAggregateUTF8Bytes
            else { continue }
            citations.append(AskDictationCitation(
                dictationID: record.id,
                createdAt: record.createdAt,
                applicationName: record.applicationName,
                delivery: record.delivery,
                text: text))
            characters = nextCharacters
            bytes = nextBytes
        }
        return citations
    }
}
