import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

/// Ranked local dictation adapter. The store checks the history consent in the
/// same read as the rows, and only whole dictations within one prompt budget
/// are cited.
public struct LocalAskDictationRetrieval: AskDictationRetrieving {
    static let candidateLimit = 24
    static let maximumQueryVariants = 3

    private let store: MeetingStore
    private let expander: BilingualSearchQueryExpander

    public init(
        store: MeetingStore,
        expander: BilingualSearchQueryExpander = .init()
    ) {
        self.store = store
        self.expander = expander
    }

    public func retrieve(question: String, limit: Int) async throws -> AskDictationEvidence {
        let queries = Array(expander.expand(question).prefix(Self.maximumQueryVariants))
        guard let records = try await store.dictationRecordsForAsk(
            matchingAny: queries,
            limit: Self.candidateLimit)
        else { return .historyOff }
        try Task.checkCancellation()
        return .found(Self.select(records, limit: limit))
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
