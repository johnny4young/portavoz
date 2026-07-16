import Foundation
import PortavozCore

/// The "Hallazgos ✦ de tu semana" of the Insights dashboard (design system
/// 3a): findings detected 100% locally from your own meetings — never
/// invented. Pure so detection is deterministic and testable. Two honest
/// signals today: meetings that produced no decision, and domain terms that
/// keep recurring across meetings.
public enum InsightsFindings {
    /// Everything a finding needs about one meeting, assembled by the caller
    /// from stored transcript + summary.
    public struct MeetingFact: Sendable, Equatable {
        public let id: MeetingID
        public let startedAt: Date
        public let seconds: TimeInterval
        /// The meeting has been summarized — only then can we judge whether it
        /// reached a decision (an un-summarized meeting is simply unjudged).
        public let hasSummary: Bool
        /// The latest summary carries at least one decision or action item.
        public let hasDecision: Bool
        /// Concatenated transcript text, for recurring-topic mining.
        public let transcript: String

        public init(
            id: MeetingID, startedAt: Date, seconds: TimeInterval,
            hasSummary: Bool, hasDecision: Bool, transcript: String
        ) {
            self.id = id
            self.startedAt = startedAt
            self.seconds = seconds
            self.hasSummary = hasSummary
            self.hasDecision = hasDecision
            self.transcript = transcript
        }
    }

    /// Meetings that closed without a single decision or action item — and how
    /// much time they took. `mostRecent` drives the card's jump-in action.
    public struct NoDecision: Sendable, Equatable {
        public let meetingIDs: [MeetingID]
        public let totalSeconds: TimeInterval
        public let mostRecent: MeetingID
        public var count: Int { meetingIDs.count }
    }

    /// A domain-looking term (acronym, CamelCase, letter+digit code) that
    /// recurs across several meetings — a topic that keeps coming up.
    public struct RecurringTopic: Sendable, Equatable, Identifiable {
        public let term: String
        public let meetingIDs: [MeetingID]
        /// The most recent meeting the term appears in (the card's action).
        public let mostRecent: MeetingID
        public var count: Int { meetingIDs.count }
        public var id: String { term.lowercased() }
    }

    /// Flag time lost to decision-less meetings once at least two of them
    /// happened — a single short sync isn't worth a callout.
    public static func noDecision(_ facts: [MeetingFact], minMeetings: Int = 2) -> NoDecision? {
        let idle = facts
            .filter { $0.hasSummary && !$0.hasDecision }
            .sorted { $0.startedAt > $1.startedAt }
        guard idle.count >= minMeetings, let recent = idle.first else { return nil }
        return NoDecision(
            meetingIDs: idle.map(\.id),
            totalSeconds: idle.reduce(0) { $0 + $1.seconds },
            mostRecent: recent.id)
    }

    /// Salient terms appearing in at least `minMeetings` distinct meetings,
    /// most-recurring first. A term is counted once per meeting. `exclude`
    /// (lowercased) drops known participant names — a person who shows up a
    /// lot is a participant, not a topic.
    ///
    /// Two passes so English sentence-openers ("Thank", "It's") never read as
    /// a topic: pass 1 builds the set of terms that are *strong* (acronym /
    /// CamelCase / letter+digit) or appear capitalized MID-sentence somewhere
    /// (the mark of a proper noun); pass 2 counts only those terms.
    public static func recurringTopics(
        _ facts: [MeetingFact], exclude: Set<String> = [], minMeetings: Int = 2, limit: Int = 3
    ) -> [RecurringTopic] {
        let perFact = facts.map { (fact: $0, terms: termOccurrences(in: $0.transcript)) }

        var proper: Set<String> = []
        var display: [String: String] = [:]
        for entry in perFact {
            for term in entry.terms where term.isStrong || term.midSentence {
                proper.insert(term.key)
                if display[term.key] == nil { display[term.key] = term.display }
            }
        }

        var byTerm: [String: (ids: [MeetingID], latest: Date)] = [:]
        for entry in perFact {
            let keys = Set(entry.terms.map(\.key)).intersection(proper).subtracting(exclude)
            for key in keys {
                if var acc = byTerm[key] {
                    acc.ids.append(entry.fact.id)
                    acc.latest = max(acc.latest, entry.fact.startedAt)
                    byTerm[key] = acc
                } else {
                    byTerm[key] = (ids: [entry.fact.id], latest: entry.fact.startedAt)
                }
            }
        }

        return byTerm
            .filter { $0.value.ids.count >= minMeetings }
            .sorted { first, second in
                first.value.ids.count != second.value.ids.count
                    ? first.value.ids.count > second.value.ids.count
                    : first.key < second.key
            }
            .prefix(limit)
            .map { key, value in
                RecurringTopic(
                    term: display[key] ?? key, meetingIDs: value.ids, mostRecent: value.ids.last!)
            }
    }

    private struct TermHit {
        let key: String
        let display: String
        let isStrong: Bool
        let midSentence: Bool
    }

    /// Every candidate topic term in one text, deduped, flagged for whether it
    /// is a "strong" shape and whether it ever appeared capitalized away from
    /// a sentence start.
    private static func termOccurrences(in text: String) -> [TermHit] {
        var map: [String: (display: String, strong: Bool, mid: Bool)] = [:]
        var atSentenceStart = true
        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            let token = trim(raw)
            let strong = isStrongTerm(token)
            let proper = isProperNounShape(token)
            if strong || proper {
                let key = token.lowercased()
                var entry = map[key] ?? (token, false, false)
                if strong { entry.strong = true }
                if proper && !atSentenceStart { entry.mid = true }
                map[key] = entry
            }
            if let last = raw.last {
                atSentenceStart = ".!?…".contains(last)
            }
        }
        return map.map { key, value in
            TermHit(key: key, display: value.display, isStrong: value.strong, midSentence: value.mid)
        }
    }

    private static let acronymStoplist: Set<String> = ["OK", "AM", "PM", "TV", "ID", "IDs", "URL"]

    private static func trim(_ raw: Substring) -> String {
        String(raw.drop(while: { !$0.isLetter && !$0.isNumber })
            .reversed()
            .drop(while: { !$0.isLetter && !$0.isNumber })
            .reversed())
    }

    /// Acronym (QVTL), letter+digit code (Qord2M), or CamelCase (WhisperKit) —
    /// shapes that are topics wherever they appear, sentence start or not.
    static func isStrongTerm(_ token: String) -> Bool {
        guard token.count >= 2, token.count <= 24, !acronymStoplist.contains(token),
            !token.contains(where: { $0 == "'" || $0 == "\u{2019}" })
        else { return false }
        let letters = token.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        if token.contains(where: \.isNumber) { return true }
        if letters.allSatisfy(\.isUppercase) { return token.count <= 6 }  // acronym
        let body = token.dropFirst()
        return body.contains(where: \.isUppercase) && token.contains(where: \.isLowercase)
    }

    /// A plain Capitalized word (Zephyr, Aurora) long enough to be a name — a
    /// topic only when it also shows up mid-sentence (see `recurringTopics`).
    /// Contractions (It's, We've) are rejected so they never qualify.
    static func isProperNounShape(_ token: String) -> Bool {
        token.count >= 4 && token.count <= 24
            && token.first?.isUppercase == true
            && !token.contains(where: { $0 == "'" || $0 == "\u{2019}" })
            && token.dropFirst().allSatisfy(\.isLowercase)
    }

    /// True for any shape the topic miner considers — used by tests.
    static func looksLikeTopic(_ token: String) -> Bool {
        isStrongTerm(token) || isProperNounShape(token)
    }
}
