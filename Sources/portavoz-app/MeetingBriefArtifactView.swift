import ApplicationKit
import PortavozCore
import SwiftUI

/// One renderer for the immutable brief artifact used by the Library manual
/// flow and the menu-bar Skill's exact preview/result. Navigation is optional:
/// confirmation renders citations as evidence, never as competing actions.
struct MeetingBriefArtifactView: View {
    let brief: MeetingBrief
    let openMeeting: (@MainActor (MeetingID) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !brief.event.attendees.isEmpty {
                Text(brief.event.attendees.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            knowledge
            relatedMeetings
            openItems
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack {
            Label(brief.event.title, systemImage: "calendar")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("brief-title")
            Spacer()
            Text(brief.event.startDate.formatted(
                date: .omitted,
                time: .shortened))
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var knowledge: some View {
        if !brief.whatToKnow.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("What to know")
                ForEach(brief.whatToKnow) { point in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("• \(point.text)").textSelection(.enabled)
                        source(
                            title: point.meetingTitle,
                            meetingID: point.meetingID,
                            identifier: "brief-knowledge-\(point.id.uuidString)")
                    }
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder private var relatedMeetings: some View {
        if !brief.related.isEmpty {
            sectionTitle("Related meetings")
            ForEach(brief.related) { related in
                source(
                    title: related.title,
                    detail: reasonText(related),
                    overview: related.overview,
                    meetingID: related.meetingID,
                    identifier: "brief-related-\(related.meetingID.rawValue.uuidString)")
            }
        }
    }

    @ViewBuilder private var openItems: some View {
        if !brief.openItems.isEmpty {
            sectionTitle("Still open")
            ForEach(brief.openItems) { open in
                Label(open.text, systemImage: "circle")
                    .font(.caption)
                    .lineLimit(2)
                    .accessibilityIdentifier("brief-open-\(open.id.uuidString)")
            }
        }
    }

    @ViewBuilder private func source(
        title: String,
        detail: String? = nil,
        overview: String? = nil,
        meetingID: MeetingID,
        identifier: String
    ) -> some View {
        let label = sourceLabel(title: title, detail: detail, overview: overview)
        if let openMeeting {
            Button { openMeeting(meetingID) } label: { label }
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier)
        } else {
            label.accessibilityIdentifier(identifier)
        }
    }

    private func sourceLabel(
        title: String,
        detail: String?,
        overview: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.medium))
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(PVDesign.accent.opacity(0.9))
                    .lineLimit(1)
            }
            if let overview, !overview.isEmpty {
                Text(overview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func reasonText(_ related: MeetingBrief.RelatedMeeting) -> String {
        if !related.matchedTerms.isEmpty {
            return L10n.format(
                "Mentions: %@",
                related.matchedTerms.joined(separator: ", "))
        }
        return related.snippet
    }
}
