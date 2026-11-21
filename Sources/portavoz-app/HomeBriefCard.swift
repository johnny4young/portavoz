import ApplicationKit
import PortavozCore
import SwiftUI

/// Beside the countdown: what each person said in the event's previous
/// occurrence, with that meeting's voice strip. A row opens the source
/// meeting at its line; the rest of the card opens the full brief.
struct HomeBriefCard: View {
    let preview: LibraryModel.BriefPreview
    /// The previous occurrence, when the library has it.
    let source: Meeting?
    let strip: VoiceStripColumns
    let briefDisabled: Bool
    let onBrief: () -> Void
    let onOpenLine: (MeetingID, TimeInterval?) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private static let radius: CGFloat = 16
    private static let nameWidth: CGFloat = 84
    private static let quote: PVDisplayStyle = {
        var style = PVDisplayStyle.heard
        style.size = 17.5
        return style
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let lines = preview.lines, !lines.people.isEmpty {
                if !strip.columns.isEmpty {
                    stripRow.padding(.top, 12).padding(.bottom, 10)
                }
                ForEach(lines.people, id: \.speakerID) { person in
                    if let line = person.lead {
                        Rectangle().fill(PVDesign.line).frame(height: 1)
                        row(person, line: line, meetingID: lines.sourceMeetingID)
                    }
                }
            } else {
                Text(preview.lines == nil
                    ? L10n.text("Nothing from a previous meeting yet.")
                    : L10n.text("Nobody was heard last time."))
                    .font(.callout)
                    .foregroundStyle(PVDesign.ink3)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("home-brief-empty")
            }
        }
        .padding(.top, 16)
        .padding(.horizontal, 22)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PVDesign.card, in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(PVDesign.line)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .onTapGesture { if !briefDisabled { onBrief() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-brief")
    }

    private var header: some View {
        Button(action: onBrief) {
            HStack(spacing: 7) {
                PVCardCaption(
                    text: L10n.text("Brief · what they said last time"),
                    systemImage: ChipLabel.generatedSymbol, tint: PVDesign.green)
                    .lineLimit(1)
                Spacer(minLength: PVDesign.space2)
                if let source {
                    Text(source.dayAndLength)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PVDesign.ink3)
                        .lineLimit(1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(briefDisabled)
        .help("See who's coming, related meetings and open to-dos")
        .accessibilityIdentifier("home-brief-open")
    }

    /// The strip beside its shares when they fit, above them otherwise.
    private var stripRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                VoiceStrip(strip, size: .card).frame(width: 210)
                HStack(spacing: 14) { VoiceLegend(cast: strip.cast) }.fixedSize()
            }
            VStack(alignment: .leading, spacing: PVDesign.space2) {
                VoiceStrip(strip, size: .card)
                FlowLayout(spacing: 14, rowSpacing: 4) { VoiceLegend(cast: strip.cast) }
            }
        }
    }

    private func row(
        _ person: MeetingBriefLines.Person, line: MeetingBriefLines.Line, meetingID: MeetingID
    ) -> some View {
        Button {
            onOpenLine(meetingID, line.segmentID == nil ? nil : line.time)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(VoicePalette.color(tint(person), colorScheme: colorScheme))
                        .frame(width: 10, height: 10)
                    Text(Self.name(person))
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(PVDesign.ink)
                        .lineLimit(1)
                }
                .frame(width: Self.nameWidth, alignment: .leading)
                .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    if line.kind == .quote {
                        Text(L10n.format("“%@”", line.text))
                            .pvDisplay(Self.quote)
                            .foregroundStyle(PVDesign.ink)
                    } else {
                        Text(line.text)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(PVDesign.ink)
                    }
                    if let meta = Self.meta(line) {
                        Text(meta)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(PVDesign.ink3)
                    }
                }
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open the meeting at this moment")
        .accessibilityIdentifier("home-brief-person-\(person.speakerID.rawValue.uuidString)")
    }

    private func tint(_ person: MeetingBriefLines.Person) -> VoiceCast.Tint {
        person.isMe ? .you : strip.cast.tint(for: person.speakerID)
    }

    nonisolated static func name(_ person: MeetingBriefLines.Person) -> String {
        VoiceName.of(isMe: person.isMe, name: person.displayName, label: person.label)
    }

    /// "12:40 · still unresolved"; a line without transcript evidence has no time.
    nonisolated static func meta(
        _ line: MeetingBriefLines.Line, now: Date = Date(), calendar: Calendar = .current
    ) -> String? {
        let time = line.segmentID == nil
            ? nil : ClockFormat.mmss(line.time, locale: AppLanguage.current.locale)
        let parts = [time, status(line.status, now: now, calendar: calendar)].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    nonisolated static func status(
        _ status: MeetingBriefLines.Status, now: Date, calendar: Calendar
    ) -> String? {
        switch status {
        case .said: return nil
        case .unresolved: return L10n.text("still unresolved")
        case .closed: return L10n.text("closed")
        case .open(nil): return L10n.text("open")
        case .open(let due?):
            if calendar.isDate(due, inSameDayAs: now) { return L10n.text("open, due today") }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
               calendar.isDate(due, inSameDayAs: tomorrow) {
                return L10n.text("open, due tomorrow")
            }
            if due < now { return L10n.text("open, overdue") }
            return L10n.format("open, due %@", due.formatted(Meeting.dayStyle))
        }
    }
}
