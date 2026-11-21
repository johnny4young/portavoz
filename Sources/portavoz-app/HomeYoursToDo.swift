import ApplicationKit
import PortavozCore
import SwiftUI

/// Open to-dos, each saying who said it, where and when, with its owner and
/// due day. Checking one off is the same durable action as in Radar.
struct HomeYoursToDo: View {
    let items: ArraySlice<LibraryOpenItem>
    let totalOpen: Int
    let sources: [UUID: OpenItemSource]
    let strips: [MeetingID: VoiceStripColumns]
    let suggestionsToReview: Int
    let onToggle: (UUID, Bool) -> Void
    let onOpen: (MeetingID, TimeInterval?) -> Void
    let onOpenRadar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeSectionHeader(title: L10n.text("Yours to do")) {
                if let radarLink = Self.radarLink(suggestions: suggestionsToReview, hidden: totalOpen - items.count) {
                    Button(action: onOpenRadar) {
                        HStack(spacing: 3) {
                            Text(radarLink)
                            Image(systemName: "chevron.right").imageScale(.small)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PVDesign.green)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Review what Portavoz suggested in Radar")
                    .accessibilityIdentifier("home-todo-radar")
                }
            }
            if items.isEmpty { HomeSectionEmpty(key: "All caught up — nothing open.") }
            ForEach(items) { open in
                HomeSectionRule()
                row(open)
            }
        }
    }

    /// Suggestions waiting lead; otherwise the to-dos that did not fit.
    nonisolated static func radarLink(suggestions: Int, hidden: Int) -> String? {
        if suggestions == 1 { return L10n.text("1 suggestion to review in Radar") }
        if suggestions > 1 { return L10n.format("%d suggestions to review in Radar", suggestions) }
        return hidden > 0 ? L10n.format("%d more in Radar", hidden) : nil
    }

    private func row(_ open: LibraryOpenItem) -> some View {
        let source = sources[open.id]
        return HStack(alignment: .firstTextBaseline, spacing: 11) {
            Toggle(isOn: Binding(get: { open.item.isDone }, set: { onToggle(open.id, $0) })) { EmptyView() }
                .toggleStyle(.pvCheckbox)
                .labelsHidden()
                .accessibilityLabel(Text(open.item.text))
                .accessibilityIdentifier("home-todo-toggle-\(open.id.uuidString)")
            Button {
                onOpen(open.meetingID, source?.time)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: PVDesign.space2) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(open.item.text)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(PVDesign.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        provenance(open, source: source)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let owner = source?.owner {
                        HomeChip(text: Self.ownerChip(owner, due: source?.dueAt), isYou: owner.isMe)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open the meeting this to-do came from")
            .accessibilityIdentifier("home-todo-\(open.id.uuidString)")
        }
        .padding(.vertical, 10)
    }

    /// "● You said it · Sprint Demo · 02:18"; the title alone when nobody is known.
    private func provenance(_ open: LibraryOpenItem, source: OpenItemSource?) -> some View {
        HStack(spacing: 6) {
            if let saidBy = source?.saidBy {
                VoiceDot(tint: tint(saidBy, in: open.meetingID))
                Text(Self.whoSaid(saidBy, ownerSaidIt: source?.ownerSaidIt ?? true))
                    .fontWeight(.semibold)
                    .foregroundStyle(PVDesign.ink2)
            }
            Text(Self.whereSaid(open, time: source?.time, led: source?.saidBy != nil))
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(PVDesign.ink3)
        .lineLimit(1)
    }

    private func tint(_ voice: OpenItemSource.Voice, in meetingID: MeetingID) -> VoiceCast.Tint {
        voice.isMe ? .you : strips[meetingID]?.cast.tint(for: voice.speakerID) ?? .grey
    }

    nonisolated static func name(_ voice: OpenItemSource.Voice) -> String {
        HomeVoiceName.of(isMe: voice.isMe, name: voice.displayName, label: voice.label)
    }

    nonisolated static func whoSaid(_ voice: OpenItemSource.Voice, ownerSaidIt: Bool) -> String {
        switch (voice.isMe, ownerSaidIt) {
        case (true, true): L10n.text("You said it")
        case (true, false): L10n.text("You asked")
        case (false, true): L10n.format("%@ said it", name(voice))
        case (false, false): L10n.format("%@ asked", name(voice))
        }
    }

    nonisolated static func whereSaid(_ open: LibraryOpenItem, time: TimeInterval?, led: Bool) -> String {
        var parts = [MeetingRowTitle.display(open.meetingTitle)]
        if let time { parts.append(ClockFormat.mmss(time, locale: AppLanguage.current.locale)) }
        return (led ? "· " : "") + parts.joined(separator: " · ")
    }

    /// "You · Fri"; the owner alone without a confirmed due day.
    nonisolated static func ownerChip(
        _ owner: OpenItemSource.Voice, due: Date?, now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        guard let due else { return name(owner) }
        return "\(name(owner)) · \(Meeting.shortDay(due, now: now, calendar: calendar))"
    }
}
