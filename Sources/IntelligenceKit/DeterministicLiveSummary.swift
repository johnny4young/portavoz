import Foundation
import PortavozCore

/// A bounded, extractive checkpoint for the rolling summary.
///
/// This value is the always-available authority on Sequoia and Tahoe. Local
/// generative providers may refine its rendered Markdown, but they never own
/// the source cursor or the ability to make live summary disappear.
public struct DeterministicLiveSummaryCheckpoint: Sendable {
    public struct Extract: Equatable, Sendable {
        public let id: UUID
        public let meetingID: MeetingID
        public let speakerID: SpeakerID?
        public let speakerLabel: String
        public let channel: AudioChannel
        public let text: String
        public let language: String?
        public let startTime: TimeInterval
        public let endTime: TimeInterval
        public let relevance: Int

        public init(
            id: UUID,
            meetingID: MeetingID,
            speakerID: SpeakerID?,
            speakerLabel: String,
            channel: AudioChannel,
            text: String,
            language: String?,
            startTime: TimeInterval,
            endTime: TimeInterval,
            relevance: Int
        ) {
            self.id = id
            self.meetingID = meetingID
            self.speakerID = speakerID
            self.speakerLabel = speakerLabel
            self.channel = channel
            self.text = text
            self.language = language
            self.startTime = startTime
            self.endTime = endTime
            self.relevance = relevance
        }

        public var segment: TranscriptSegment {
            TranscriptSegment(
                id: id,
                meetingID: meetingID,
                speakerID: speakerID,
                channel: channel,
                text: text,
                language: language,
                startTime: startTime,
                endTime: endTime,
                isFinal: true)
        }
    }

    public let extracts: [Extract]
    public let markdown: String
    public let targetLanguage: String

    public init(extracts: [Extract], markdown: String, targetLanguage: String) {
        self.extracts = extracts
        self.markdown = markdown
        self.targetLanguage = targetLanguage
    }

    public var segments: [TranscriptSegment] {
        extracts.map(\.segment)
    }

    /// Provider-neutral bounded material. This stays extractive and keeps the
    /// same chronological, speaker-labeled evidence a refiner receives.
    public var material: String {
        extracts.map { "\($0.speakerLabel): \($0.text)" }
            .joined(separator: "\n")
    }
}

/// Pure incremental reducer used before any optional model call.
///
/// It retains the strongest and newest exact transcript excerpts under fixed
/// row/character limits. It performs no inference, network request, model
/// load, persistence, or locale-dependent process lookup.
public enum DeterministicLiveSummary {
    public static let maximumExtracts = 24
    public static let maximumCharacters = 6_000
    public static let maximumExtractCharacters = 320
    public static let maximumContextItems = 8
    public static let maximumContextCharacters = 280
    private static let recentExtractReservation = 8

    public static func advance(
        checkpoint: DeterministicLiveSummaryCheckpoint?,
        segments: [TranscriptSegment],
        speakers: [Speaker],
        contextItems: [ContextItem],
        targetLanguage: String
    ) -> DeterministicLiveSummaryCheckpoint? {
        var labels: [SpeakerID: String] = [:]
        for speaker in speakers {
            // Corrupt or synthesized input must never turn duplicate speaker
            // identities into a Dictionary initializer trap. The newest
            // display value is the same last-writer rule used for revisions.
            labels[speaker.id] = speaker.displayName ?? speaker.label
        }
        var byID: [UUID: DeterministicLiveSummaryCheckpoint.Extract] = [:]
        for extract in checkpoint?.extracts ?? [] {
            byID[extract.id] = extract
        }

        for segment in segments {
            guard let extract = extract(
                segment,
                speakerLabel: segment.speakerID.flatMap { labels[$0] }
                    ?? (segment.channel == .microphone ? "Me" : "Them")
            ) else { continue }
            byID[segment.id] = extract
        }

        let selected = select(Array(byID.values))
        guard !selected.isEmpty else { return nil }
        let resolvedLanguage = LanguageCode(targetLanguage)?.identifier
            ?? checkpoint?.targetLanguage
            ?? "en"
        return DeterministicLiveSummaryCheckpoint(
            extracts: selected,
            markdown: render(
                selected,
                contextItems: contextItems,
                targetLanguage: resolvedLanguage),
            targetLanguage: resolvedLanguage)
    }

    private static func extract(
        _ segment: TranscriptSegment,
        speakerLabel: String
    ) -> DeterministicLiveSummaryCheckpoint.Extract? {
        let normalized = segment.text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let text = clipped(normalized, limit: maximumExtractCharacters)
        return DeterministicLiveSummaryCheckpoint.Extract(
            id: segment.id,
            meetingID: segment.meetingID,
            speakerID: segment.speakerID,
            speakerLabel: speakerLabel,
            channel: segment.channel,
            text: text,
            language: segment.language,
            startTime: segment.startTime,
            endTime: segment.endTime,
            relevance: relevance(of: text))
    }

    private static func select(
        _ extracts: [DeterministicLiveSummaryCheckpoint.Extract]
    ) -> [DeterministicLiveSummaryCheckpoint.Extract] {
        let ranked = extracts.sorted { lhs, rhs in
            if lhs.relevance != rhs.relevance {
                return lhs.relevance > rhs.relevance
            }
            if lhs.startTime != rhs.startTime {
                return lhs.startTime > rhs.startTime
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        let newest = extracts.sorted { lhs, rhs in
            if lhs.startTime != rhs.startTime { return lhs.startTime > rhs.startTime }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        var selected: [DeterministicLiveSummaryCheckpoint.Extract] = []
        var selectedIDs: Set<UUID> = []
        var characters = 0
        func admit(_ extract: DeterministicLiveSummaryCheckpoint.Extract) {
            guard !selectedIDs.contains(extract.id) else { return }
            let cost = extract.speakerLabel.count + extract.text.count + 4
            guard selected.isEmpty || characters + cost <= maximumCharacters else {
                return
            }
            selected.append(extract)
            selectedIDs.insert(extract.id)
            characters += cost
        }
        // A wall of older action/decision wording must not make a rolling
        // checkpoint blind to what was just said. Reserve a bounded recent
        // slice, then spend the remaining capacity on highest-signal evidence.
        for extract in newest.prefix(recentExtractReservation) {
            admit(extract)
        }
        for extract in ranked where selected.count < maximumExtracts {
            admit(extract)
        }
        return selected.sorted { lhs, rhs in
            if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func relevance(of text: String) -> Int {
        let normalized = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        var score = min(text.count / 80, 3)
        if text.last.map({ "?!\u{00BF}\u{00A1}".contains($0) }) == true { score += 2 }
        if containsAny(normalized, terms: decisionTerms) { score += 5 }
        if containsAny(normalized, terms: actionTerms) { score += 4 }
        if containsAny(normalized, terms: riskTerms) { score += 3 }
        return score
    }

    private static func containsAny(_ text: String, terms: [String]) -> Bool {
        terms.contains { text.contains($0) }
    }

    private static func render(
        _ extracts: [DeterministicLiveSummaryCheckpoint.Extract],
        contextItems: [ContextItem],
        targetLanguage: String
    ) -> String {
        let isSpanish = LanguageCode(targetLanguage)?.identifier == "es"
        let title = isSpanish ? "## Puntos clave en vivo" : "## Live highlights"
        var lines = [title]
        lines.append(contentsOf: extracts.map {
            "- **\(escapedMarkdown($0.speakerLabel)):** \(escapedMarkdown($0.text))"
        })

        let notes = contextItems
            .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(maximumContextItems)
        if !notes.isEmpty {
            lines.append("")
            lines.append(isSpanish ? "## Tus notas" : "## Your notes")
            lines.append(contentsOf: notes.map {
                "- " + escapedMarkdown(clipped(
                    $0.content.trimmingCharacters(in: .whitespacesAndNewlines),
                    limit: maximumContextCharacters))
            })
        }
        return lines.joined(separator: "\n")
    }

    private static func clipped(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let boundary = max(limit - 1, 1)
        return String(text.prefix(boundary)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func escapedMarkdown(_ text: String) -> String {
        let syntax = CharacterSet(charactersIn: "\\`*_{}[]<>()#!|")
        return text.unicodeScalars.reduce(into: "") { result, scalar in
            if syntax.contains(scalar) { result.append("\\") }
            result.unicodeScalars.append(scalar)
        }
    }

    private static let decisionTerms = [
        "decidimos", "decision", "acordamos", "aprobado", "approved",
        "we decided", "we agreed", "the decision", "go with"
    ]

    private static let actionTerms = [
        "voy a", "vamos a", "tengo que", "necesitamos", "siguiente paso",
        "me encargo", "will do", "we will", "i will", "need to",
        "next step", "action item", "follow up", "owner"
    ]

    private static let riskTerms = [
        "riesgo", "bloqueo", "bloqueado", "problema", "fecha limite",
        "risk", "blocker", "blocked", "issue", "deadline"
    ]
}
