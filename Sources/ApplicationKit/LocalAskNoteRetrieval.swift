import Foundation
import IntelligenceKit
import StorageKit

/// Exact-first local-note adapter. It queries the dedicated FTS projection and
/// admits only complete raw notes within one aggregate prompt budget.
public struct LocalAskNoteRetrieval: AskNoteRetrieving {
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

    public func retrieve(
        question: String,
        limit: Int,
        onEvidence: @escaping AskNoteEvidenceReceiver
    ) async throws -> [AskNoteCitation] {
        guard limit > 0 else {
            await onEvidence(AskNoteEvidenceUpdate(
                phase: .fused,
                citations: []))
            return []
        }
        let queries = Array(expander.expand(question).prefix(
            Self.maximumQueryVariants))
        var seen = Set<UUID>()
        var candidates: [NoteSearchHit] = []
        var didPublishLexical = false
        for query in queries {
            try Task.checkCancellation()
            let hits = try await store.searchNotes(
                query,
                limit: Self.candidateLimit,
                requireAll: false)
            for hit in hits where seen.insert(hit.noteID).inserted {
                candidates.append(hit)
            }
            let lexical = Self.select(candidates, limit: limit)
            if !didPublishLexical, !lexical.isEmpty {
                await onEvidence(AskNoteEvidenceUpdate(
                    phase: .lexical,
                    citations: lexical))
                didPublishLexical = true
            }
        }
        try Task.checkCancellation()
        let citations = Self.select(candidates, limit: limit)
        await onEvidence(AskNoteEvidenceUpdate(
            phase: .fused,
            citations: citations))
        try Task.checkCancellation()
        return citations
    }

    static func select(
        _ hits: [NoteSearchHit],
        limit: Int
    ) -> [AskNoteCitation] {
        var characters = 0
        var bytes = 0
        var citations: [AskNoteCitation] = []
        for hit in hits where citations.count < limit {
            let text = hit.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let nextCharacters = characters + text.count
            let nextBytes = bytes + text.utf8.count
            guard !text.isEmpty,
                  text == hit.text,
                  text.count <= AskNoteLimits.maximumCitationCharacters,
                  text.utf8.count <= AskNoteLimits.maximumCitationUTF8Bytes,
                  nextCharacters <= AskNoteLimits.maximumAggregateCharacters,
                  nextBytes <= AskNoteLimits.maximumAggregateUTF8Bytes
            else { continue }
            citations.append(AskNoteCitation(
                noteID: hit.noteID,
                meetingID: hit.meetingID,
                meetingTitle: hit.meetingTitle,
                author: .localUser,
                authoredAt: hit.authoredAt,
                timestamp: hit.timestamp,
                text: text,
                provenance: .userContextItem))
            characters = nextCharacters
            bytes = nextBytes
        }
        return citations
    }
}
