import ApplicationKit
import PortavozCore
import SwiftUI

/// Pre-meeting brief (M13b, Granola Briefs pattern): before your next
/// calendar event, what you should walk in knowing — who's coming, the
/// related past meetings, what's still open with them, and an on-device
/// "what to know" synthesis. Loads only when calendar access was already
/// granted (never prompts on its own).
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
            .foregroundStyle(PVDesign.accent)
            .padding(.leading, 12)
            .accessibilityIdentifier("brief-knowledge-\(point.id.uuidString)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(brief.event.title, systemImage: "calendar")
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("brief-title")
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
                            Text(reasonText(related))
                                .font(.caption2)
                                .foregroundStyle(PVDesign.accent.opacity(0.9))
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
                    .accessibilityIdentifier(
                        "brief-related-\(related.meetingID.rawValue.uuidString)")
                }
            }
            if !brief.openItems.isEmpty {
                Text("Still open")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(brief.openItems) { open in
                    Label(open.text, systemImage: "circle")
                        .font(.caption)
                        .lineLimit(2)
                        .accessibilityIdentifier("brief-open-\(open.id.uuidString)")
                }
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .accessibilityIdentifier("brief-close-button")
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

    private func reasonText(_ related: MeetingBrief.RelatedMeeting) -> String {
        if !related.matchedTerms.isEmpty {
            return L10n.format(
                "Mentions: %@",
                related.matchedTerms.joined(separator: ", "))
        }
        return related.snippet
    }
}
