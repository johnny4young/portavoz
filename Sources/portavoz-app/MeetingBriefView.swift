import IntegrationsKit
import IntelligenceKit
import PortavozCore
import StorageKit
import SwiftUI

/// Pre-meeting brief (M13b, Granola Briefs pattern): before your next
/// calendar event, what you should walk in knowing — who's coming, the
/// related past meetings, what's still open with them, and an on-device
/// "what to know" synthesis. Loads only when calendar access was already
/// granted (never prompts on its own).
struct MeetingBrief {
    let event: UpcomingEvent
    let related: [RelatedMeeting]
    let openItems: [MeetingStore.OpenActionItem]
    /// "What to know" bullets, each citing the meeting it came from —
    /// ungrounded/filler bullets are gated out by BriefSynthesizer.
    let whatToKnow: [KnowPoint]

    struct KnowPoint: Identifiable {
        let id = UUID()
        let text: String
        let meetingID: MeetingID
        let meetingTitle: String
    }

    struct RelatedMeeting: Identifiable {
        var id: MeetingID { meetingID }
        let meetingID: MeetingID
        let title: String
        let overview: String
        /// Why it surfaced: matched event terms, or a passage snippet when
        /// the match is purely semantic.
        let reason: String
    }

    /// Related = meetings whose transcripts mention the event's attendees
    /// or title words, ranked by hit count. Pure store work; the optional
    /// FM synthesis reuses the RAG answerer (already gated-tested).
    static func build(for event: UpcomingEvent, store: MeetingStore) async -> MeetingBrief? {

        // Hybrid retrieval (lexical + semantic, same engine as Ask) scored
        // and thresholded by BriefRelevance — weak single-passage matches
        // are dropped instead of shown (field bug: an unrelated 1:1
        // surfaced as "related" by raw FTS hit count).
        let terms = BriefRelevance.terms(eventTitle: event.title, attendees: event.attendees)
        let query = ([event.title] + event.attendees).joined(separator: " ")
        let passages =
            (try? await AskPipeline.retrieve(question: query, store: store, limit: 12)) ?? []
        let ranked = BriefRelevance.rank(passages: passages, terms: terms)

        var related: [RelatedMeeting] = []
        for candidate in ranked {
            guard let summary = try? await store.summary(candidate.meetingID) else { continue }
            let overview = summary.draft.markdown
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first { !$0.hasPrefix("#") }
                .map(String.init) ?? ""
            let reason = candidate.matchedTerms.isEmpty
                ? String(candidate.snippet.prefix(90))
                : L10n.format("Mentions: %@", candidate.matchedTerms.joined(separator: ", "))
            related.append(RelatedMeeting(
                meetingID: candidate.meetingID, title: candidate.title,
                overview: overview, reason: reason))
        }

        let relatedIDs = Set(related.map(\.meetingID))
        let openItems = ((try? await store.openActionItems(limit: 50)) ?? [])
            .filter { relatedIDs.contains($0.meetingID) }
            .prefix(8)

        var whatToKnow: [KnowPoint] = []
        if !related.isEmpty, #available(macOS 26.0, *),
            FoundationModelSummaryProvider.unavailabilityReason() == nil {
            let passages = related.map {
                RAGPassage(
                    meetingID: $0.meetingID, meetingTitle: $0.title,
                    timestamp: 0, text: $0.overview)
            }
            let points = await BriefSynthesizer.whatToKnow(
                eventTitle: event.title, passages: passages)
            whatToKnow = points.map { point in
                let source = passages[point.passageIndex - 1]
                return KnowPoint(
                    text: point.text,
                    meetingID: source.meetingID,
                    meetingTitle: source.meetingTitle)
            }
        }

        return MeetingBrief(
            event: event,
            related: related,
            openItems: Array(openItems),
            whatToKnow: whatToKnow)
    }

}

/// The sheet the sidebar's "Next meeting" row opens.
struct MeetingBriefView: View {
    let brief: MeetingBrief
    @Binding var route: Route?
    @Environment(\.dismiss) private var dismiss

    /// One grounded bullet with its clickable source: tapping the citation
    /// jumps to the meeting the fact came from.
    private func knowRow(_ point: MeetingBrief.KnowPoint) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("• \(point.text)").textSelection(.enabled)
            Button {
                dismiss()
                route = .meeting(point.meetingID)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                    Text(point.meetingTitle).lineLimit(1)
                }
                .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(.leading, 12)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(brief.event.title, systemImage: "calendar")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(brief.event.startDate.formatted(date: .omitted, time: .shortened))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            if !brief.event.attendees.isEmpty {
                Text(brief.event.attendees.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !brief.whatToKnow.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What to know")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(brief.whatToKnow) { point in
                        knowRow(point)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            if !brief.related.isEmpty {
                Text("Related meetings")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(brief.related) { related in
                    Button {
                        dismiss()
                        route = .meeting(related.meetingID)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(related.title).font(.callout.weight(.medium))
                            Text(related.reason)
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor.opacity(0.9))
                                .lineLimit(1)
                            if !related.overview.isEmpty {
                                Text(related.overview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            if !brief.openItems.isEmpty {
                Text("Still open")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(brief.openItems, id: \.item.id) { open in
                    Label(open.item.text, systemImage: "circle")
                        .font(.caption)
                        .lineLimit(2)
                }
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button {
                    dismiss()
                    route = .recording(brief.event)
                } label: {
                    Label("Record this meeting", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("brief-record-button")
                .help("Starts recording linked to this event: the meeting gets its real title")
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
