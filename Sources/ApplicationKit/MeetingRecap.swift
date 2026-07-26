import Foundation
import IntelligenceKit
import PortavozCore

/// Who the recap speaks to. `participant` leads with that person's own
/// commitments — the difference between forwarding a document and writing
/// someone a message.
public enum RecapAudience: Hashable, Sendable {
    case everyone
    case participant(SpeakerID)
}

/// A reviewable post-meeting recap: a subject line plus a Markdown body.
///
/// It is derived from the SUMMARY, never from the transcript (D136), so
/// sharing a recap cannot leak raw speech. Nothing here is sent: the app
/// composes the draft, the user edits it, and the user chooses where it
/// goes.
public struct MeetingRecap: Equatable, Sendable {
    /// Ready for an email subject line; ignored by chat channels.
    public let subject: String
    /// The body as Markdown — `MeetingExporter.render(_:format:)` shapes it
    /// for a channel, with the same conventions as the summary copy.
    public let markdown: String

    public init(subject: String, markdown: String) {
        self.subject = subject
        self.markdown = markdown
    }
}

/// Composes the recap draft. Pure: same inputs produce the same text, with
/// no clock, no store, and no model.
public enum RecapComposer {
    public static func compose(
        meeting: Meeting,
        speakers: [Speaker],
        summary: SummaryDraft,
        audience: RecapAudience = .everyone,
        timeZone: TimeZone = .current
    ) -> MeetingRecap {
        let labels = RecapLabels.forLanguage(summary.language)
        var blocks: [String] = []
        let intro = SummaryMarkdownOutline.parse(summary.markdown).intro
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !intro.isEmpty { blocks.append(intro) }
        blocks.append(contentsOf: contentSections(of: summary))
        blocks.append(contentsOf: commitmentBlocks(
            speakers: speakers,
            items: summary.actionItems,
            audience: audience,
            labels: labels))
        blocks.append(labels.provenance)
        return MeetingRecap(
            subject: subject(for: meeting, labels: labels, timeZone: timeZone),
            markdown: blocks.joined(separator: "\n\n") + "\n")
    }

    /// Every summary section except the action items: those are re-rendered
    /// below from the library's REAL done state, so keeping the snapshot's
    /// own block would contradict it.
    private static func contentSections(of summary: SummaryDraft) -> [String] {
        SummaryMarkdownOutline.parse(summary.markdown).sections.compactMap { section in
            guard !StructuredSummary.isActionItemsHeading(section.heading) else { return nil }
            let body = section.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return "## \(section.heading)\n\(body)"
        }
    }

    /// Open commitments only: a recap looks forward. When everything is
    /// closed the recap says so rather than printing an empty heading.
    private static func commitmentBlocks(
        speakers: [Speaker],
        items: [ActionItem],
        audience: RecapAudience,
        labels: RecapLabels
    ) -> [String] {
        let open = items.filter { !$0.isDone }
        let names = speakers.reduce(into: [SpeakerID: String]()) { names, speaker in
            names[speaker.id] = speaker.displayName ?? speaker.label
        }
        func lines(_ items: [ActionItem], withOwner: Bool) -> String {
            items.map { item in
                guard withOwner, let owner = item.ownerSpeakerID.flatMap({ names[$0] }) else {
                    return "- \(item.text)"
                }
                return "- \(owner): \(item.text)"
            }
            .joined(separator: "\n")
        }

        // Nothing open is a fact about the MEETING, not about the reader:
        // telling one participant only "nothing is assigned to you" would
        // imply the others still owe something.
        guard !open.isEmpty else {
            return ["## \(labels.commitments)\n\(labels.noneOpen)"]
        }
        switch audience {
        case .everyone:
            return ["## \(labels.commitments)\n\(lines(open, withOwner: true))"]
        case .participant(let speakerID):
            let mine = open.filter { $0.ownerSpeakerID == speakerID }
            let others = open.filter { $0.ownerSpeakerID != speakerID }
            var blocks = [
                "## \(labels.yourCommitments)\n"
                    + (mine.isEmpty ? labels.noneForYou : lines(mine, withOwner: false))
            ]
            if !others.isEmpty {
                blocks.append("## \(labels.otherCommitments)\n\(lines(others, withOwner: true))")
            }
            return blocks
        }
    }

    private static func subject(
        for meeting: Meeting,
        labels: RecapLabels,
        timeZone: TimeZone
    ) -> String {
        let title = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: labels.language.identifier)
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "\(labels.subjectPrefix): \(title.isEmpty ? labels.untitled : title)"
            + " — \(formatter.string(from: meeting.startedAt))"
    }
}

/// The recap speaks the MEETING's language, not the app's interface
/// language (D136): it is addressed to the people who were in the room.
/// These labels are therefore content, not UI chrome, and never travel
/// through `L10n`.
struct RecapLabels {
    let language: LanguageCode
    let subjectPrefix: String
    let untitled: String
    let commitments: String
    let yourCommitments: String
    let otherCommitments: String
    let noneOpen: String
    let noneForYou: String
    let provenance: String

    static func forLanguage(_ rawValue: String?) -> RecapLabels {
        LanguageCode(rawValue) == .spanish ? .spanish : .english
    }

    static let english = RecapLabels(
        language: .english,
        subjectPrefix: "Recap",
        untitled: "Untitled meeting",
        commitments: "Open commitments",
        yourCommitments: "Your commitments",
        otherCommitments: "Other commitments",
        noneOpen: "Nothing was left open.",
        noneForYou: "Nothing is assigned to you.",
        // Deliberately claims only what is always true: the recap carries no
        // transcript. It does NOT claim the summary never left the device,
        // because a BYOK or remote engine may have generated it.
        provenance: "Recap written with Portavoz from the meeting summary."
            + " The transcript is not included.")

    static let spanish = RecapLabels(
        language: .spanish,
        subjectPrefix: "Resumen de la reunión",
        untitled: "Reunión sin título",
        commitments: "Pendientes",
        yourCommitments: "Tus pendientes",
        otherCommitments: "Otros pendientes",
        noneOpen: "No quedaron pendientes.",
        noneForYou: "No hay pendientes a tu nombre.",
        provenance: "Resumen escrito con Portavoz a partir del resumen de la reunión."
            + " No incluye la transcripción.")
}
