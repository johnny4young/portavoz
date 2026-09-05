import Foundation
import IntelligenceKit
import StorageKit

/// A literal reference is precision evidence, not a relevance score. Protect
/// only the leading lexical result; every other candidate retains ordinary
/// reciprocal-rank order, including semantic-only and spoken-reference hits.
enum AskCandidateFusion {
    static func fuse(
        question: String,
        lexical: [SearchHit],
        semantic: [UUID],
        resolvedLead: SearchHit?,
        limit: Int
    ) -> [UUID] {
        guard limit > 0 else { return [] }
        let fused = RAGFusion.fuse(
            lexical: lexical.map(\.segmentID), semantic: semantic, limit: limit)
        guard let lead = lexical.first,
              let resolvedLead,
              sameEvidence(lead, resolvedLead),
              let reference = soleReference(
                in: question, maximumBytes: AskRequestLimits.maximumQuestionUTF8Bytes),
              !hasExclusion(in: question),
              soleReference(
                in: lead.text, maximumBytes: AskRequestLimits.maximumCitationTextCharacters * 4) == reference,
              fused.first != lead.segmentID
        else { return fused }
        return Array(([lead.segmentID] + fused.filter { $0 != lead.segmentID }).prefix(limit))
    }

    /// Lexical and semantic reads may straddle a correction. Never use an old
    /// passage's reference to promote a different final citation snapshot.
    private static func sameEvidence(_ lexical: SearchHit, _ resolved: SearchHit) -> Bool {
        lexical.segmentID == resolved.segmentID
            && lexical.meetingID == resolved.meetingID
            && lexical.sourceSegmentIDs == resolved.sourceSegmentIDs
            && lexical.transcriptRevision == resolved.transcriptRevision
            && lexical.startTime == resolved.startTime
            && lexical.text == resolved.text
    }

    /// Deliberately conservative: plain identifiers only, not dates, numbers,
    /// natural names, version inference, prefixes or a guessed ASR correction.
    static func soleReference(in text: String, maximumBytes: Int) -> String? {
        guard maximumBytes > 0, text.utf8.count <= maximumBytes else { return nil }
        var reference: String?
        for token in tokens(in: text) {
            guard token.wholeMatch(of: #/[A-Za-z][A-Za-z0-9]{0,31}-[0-9]{1,16}/#) != nil else { continue }
            let value = token.lowercased()
            if let reference, reference != value { return nil }
            reference = value
        }
        return reference
    }

    private static func hasExclusion(in question: String) -> Bool {
        let folded = question.lowercased()
        if folded.contains("n't") || folded.contains("n’t") { return true }
        let exclusions: Set<String> = [
            "not", "without", "exclude", "excluding", "except",
            "no", "sin", "excepto", "excluye", "excluir"
        ]
        return tokens(in: folded).contains { exclusions.contains(String($0)) }
    }

    private static func tokens(in text: String) -> [Substring] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
