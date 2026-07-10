import Foundation
import IntelligenceKit
import PortavozCore

/// Ranks which past meetings are genuinely related to an upcoming event
/// (field bug jul 2026: naive FTS-by-hit-count surfaced a "blood tests" 1:1
/// as related to a sprint demo). Deterministic and explainable:
///
/// - Passages come from the HYBRID retriever (`AskPipeline`, lexical +
///   semantic), so paraphrases still match.
/// - Each candidate meeting is scored `passages + 2 × matched terms`, where
///   terms are the event's title words and attendee names actually found in
///   its passages. A minimum score gates out weak, single-passage semantic
///   noise — better an empty section than a misleading one.
/// - The matched terms double as the visible REASON ("Mentions: Trinity"),
///   so the user can see why a meeting showed up.
public enum BriefRelevance {
    public struct Related: Sendable, Equatable {
        public let meetingID: MeetingID
        public let title: String
        /// Event terms literally present in this meeting's passages.
        public let matchedTerms: [String]
        public let passageCount: Int
        /// Best passage text — the fallback reason when the match is
        /// purely semantic.
        public let snippet: String

        public var score: Int { passageCount + 2 * matchedTerms.count }
    }

    /// Words worth matching from the event: title words and attendee name
    /// parts, deduplicated, 3+ characters (shorter ones match everything).
    public static func terms(eventTitle: String, attendees: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for source in [eventTitle] + attendees {
            for word in source.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let term = String(word)
                guard term.count >= 3, seen.insert(term.lowercased()).inserted else { continue }
                result.append(term)
            }
        }
        return result
    }

    public static func rank(
        passages: [RAGPassage],
        terms: [String],
        limit: Int = 3,
        minimumScore: Int = 3
    ) -> [Related] {
        var grouped: [MeetingID: (title: String, passages: [RAGPassage])] = [:]
        for passage in passages {
            grouped[passage.meetingID, default: (passage.meetingTitle, [])].passages
                .append(passage)
        }

        var candidates: [Related] = []
        for (meetingID, group) in grouped {
            let text = group.passages.map(\.text).joined(separator: "\n")
            let matched = terms.filter {
                text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            let candidate = Related(
                meetingID: meetingID,
                title: group.title,
                matchedTerms: matched,
                passageCount: group.passages.count,
                snippet: group.passages.first?.text ?? "")
            if candidate.score >= minimumScore {
                candidates.append(candidate)
            }
        }
        candidates.sort { first, second in
            first.score != second.score
                ? first.score > second.score
                : first.title < second.title
        }
        return Array(candidates.prefix(limit))
    }
}
