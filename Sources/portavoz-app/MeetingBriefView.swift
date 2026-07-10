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
    let whatToKnow: String?

    struct RelatedMeeting: Identifiable {
        var id: MeetingID { meetingID }
        let meetingID: MeetingID
        let title: String
        let overview: String
    }

    /// Related = meetings whose transcripts mention the event's attendees
    /// or title words, ranked by hit count. Pure store work; the optional
    /// FM synthesis reuses the RAG answerer (already gated-tested).
    static func build(for event: UpcomingEvent, store: MeetingStore) async -> MeetingBrief? {

        let titleWords = event.title.split(whereSeparator: \.isWhitespace)
            .map(String.init).filter { $0.count >= 4 }
        let keywords = (event.attendees + titleWords).joined(separator: " ")

        var hitsByMeeting: [MeetingID: (title: String, count: Int)] = [:]
        if !keywords.isEmpty,
            let hits = try? await store.search(keywords, limit: 30, requireAll: false) {
            for hit in hits {
                hitsByMeeting[hit.meetingID, default: (hit.meetingTitle, 0)].count += 1
            }
        }
        let topMeetings = hitsByMeeting.sorted { $0.value.count > $1.value.count }.prefix(3)

        var related: [RelatedMeeting] = []
        for (meetingID, info) in topMeetings {
            guard let summary = try? await store.summary(meetingID) else { continue }
            let overview = summary.draft.markdown
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first { !$0.hasPrefix("#") }
                .map(String.init) ?? ""
            related.append(RelatedMeeting(
                meetingID: meetingID, title: info.title, overview: overview))
        }

        let relatedIDs = Set(related.map(\.meetingID))
        let openItems = ((try? await store.openActionItems(limit: 50)) ?? [])
            .filter { relatedIDs.contains($0.meetingID) }
            .prefix(8)

        var whatToKnow: String?
        if !related.isEmpty, #available(macOS 26.0, *),
            FoundationModelSummaryProvider.unavailabilityReason() == nil {
            let passages = related.map {
                RAGPassage(
                    meetingID: $0.meetingID, meetingTitle: $0.title,
                    timestamp: 0, text: $0.overview)
            }
            whatToKnow = try? await RAGAnswerer().answer(
                question: briefQuestion(for: event), passages: passages)
        }

        return MeetingBrief(
            event: event,
            related: related,
            openItems: Array(openItems),
            whatToKnow: whatToKnow)
    }

    private static func briefQuestion(for event: UpcomingEvent) -> String {
        let people = event.attendees.isEmpty
            ? "" : " with \(event.attendees.joined(separator: ", "))"
        return "In two or three short bullets: what should I know going into \"\(event.title)\"\(people)?"
    }
}

/// The sheet the sidebar's "Next meeting" row opens.
struct MeetingBriefView: View {
    let brief: MeetingBrief
    @Binding var route: Route?
    @Environment(\.dismiss) private var dismiss

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
            if let whatToKnow = brief.whatToKnow {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What to know")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(whatToKnow).textSelection(.enabled)
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
