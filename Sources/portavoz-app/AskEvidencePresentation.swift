import ApplicationKit
import Foundation
import PortavozCore

/// What the "Who said it" page draws for one answer, independent of SwiftUI.
enum AskEvidencePresentation {
    /// A run of answer text, or the `[n]` marker of citation `n`.
    enum Piece: Equatable {
        case text(String)
        case marker(Int)
    }

    enum Speaker: Equatable {
        /// The evidence read has not landed yet.
        case pending
        case unknown
        case voice(name: String, tint: VoiceCast.Tint)
    }

    struct Row: Identifiable, Equatable {
        let number: Int
        let citation: AskCitation
        let speaker: Speaker
        /// "Sprint Demo · today"; the time code follows separately.
        let meeting: String
        let time: String
        let strip: VoiceStripColumns?
        /// Where the moment sits on `strip`, from 0 to 1.
        let position: Double?

        var id: Int { number }
    }

    /// Splits `[n]` markers that point at a citation out of the answer; a
    /// space before a marker goes, as the marker sits against its word.
    static func pieces(of answer: String, citationCount: Int) -> [Piece] {
        var pieces: [Piece] = []
        var rest = Substring(answer)
        while let match = rest.firstMatch(of: #/ ?\[(\d{1,2})\]/#) {
            guard let number = Int(match.output.1), number >= 1, number <= citationCount else {
                append(String(rest[..<match.range.upperBound]), to: &pieces)
                rest = rest[match.range.upperBound...]
                continue
            }
            append(String(rest[..<match.range.lowerBound]), to: &pieces)
            pieces.append(.marker(number))
            rest = rest[match.range.upperBound...]
        }
        append(String(rest), to: &pieces)
        return pieces
    }

    private static func append(_ text: String, to pieces: inout [Piece]) {
        guard !text.isEmpty else { return }
        if case .text(let previous) = pieces.last {
            pieces[pieces.count - 1] = .text(previous + text)
        } else {
            pieces.append(.text(text))
        }
    }

    /// One row per citation in marker order; voices, days and strips join once the evidence lands.
    static func rows(
        citations: [AskCitation], evidence: AskEvidence?, now: Date = Date(), calendar: Calendar = .current
    ) -> [Row] {
        let cast = evidence.map { TodayPageCast(meetings: $0.strips.map { ($0.meetingID, $0.source) }) }
        return citations.enumerated().map { index, citation in
            let loaded = evidence?.rows.first { $0.number == index + 1 && $0.citation == citation }
            let day = loaded?.meetingStartedAt.map { Self.day($0, now: now, calendar: calendar) }
            let title = MeetingRowTitle.display(citation.meetingTitle)
            return Row(
                number: index + 1,
                citation: citation,
                speaker: speaker(of: loaded, in: citation.meetingID, cast: cast, loaded: evidence != nil),
                meeting: [title, day].compactMap { $0 }.joined(separator: " · "),
                time: AskMarkdown.clock(citation.timestamp),
                strip: cast?.strip(for: citation.meetingID),
                position: loaded?.position)
        }
    }

    private static func speaker(
        of row: AskEvidence.Row?, in meeting: MeetingID, cast: TodayPageCast?, loaded: Bool
    ) -> Speaker {
        guard loaded else { return .pending }
        guard let voice = row?.voice else { return .unknown }
        let isMe = voice.identity == .me
        return .voice(
            name: VoiceName.of(isMe: isMe, name: voice.name, label: voice.label),
            tint: cast?.tint(for: voice.speakerID, isMe: isMe, in: meeting) ?? .grey)
    }

    /// "today", "yesterday", else "Wed 9 Sep" in the app's language.
    static func day(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return L10n.text("today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.text("yesterday")
        }
        return date.formatted(Meeting.dayStyle)
    }

    /// "Portavoz · from 3 voices in 2 meetings", or only the meetings before voices are known.
    static func generatedFrom(voices: Int, meetings: Int) -> String {
        let meetingCount = meetings == 1 ? L10n.text("1 meeting") : L10n.format("%d meetings", meetings)
        guard voices > 0 else { return L10n.format("Portavoz · from %@", meetingCount) }
        let voiceCount = voices == 1 ? L10n.text("1 voice") : L10n.format("%d voices", voices)
        return L10n.format("Portavoz · from %@ in %@", voiceCount, meetingCount)
    }

    static func openCommitments(_ count: Int) -> String {
        count == 1 ? L10n.text("1 open commitment") : L10n.format("%d open commitments", count)
    }

    static func moments(_ count: Int) -> String {
        count == 1 ? L10n.text("1 moment") : L10n.format("%d moments", count)
    }

    /// "1.8 s" in the app's language.
    static func answerTime(_ duration: Duration) -> String {
        duration.formatted(.units(
            allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1))
            .locale(AppLanguage.current.locale))
    }

    /// The answer with who said each cited line, for the pasteboard.
    static func markdown(question: String, answer: String, rows: [Row]) -> String {
        AskMarkdown.format(
            question: question, answer: answer,
            sources: rows.map { row in
                if case .voice(let name, _) = row.speaker { return (row.citation, name) }
                return (row.citation, nil)
            })
    }
}
