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
    /// Colours the source's voices as the rest of Today does.
    let page: TodayPageCast
    let briefDisabled: Bool
    let onBrief: () -> Void
    let onOpenLine: (MeetingID, TimeInterval?) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private static let radius: CGFloat = 16
    private static let nameWidth: CGFloat = 84
    private static let quote = PVDisplayStyle.heard.sized(17.5)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let lines = preview.lines, !lines.people.isEmpty {
                if let strip = page.strip(for: lines.sourceMeetingID), !strip.columns.isEmpty {
                    stripRow(strip).padding(.top, 12).padding(.bottom, 10)
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
            // The source's day moves under the kicker before either truncates.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    caption.lineLimit(1)
                    Spacer(minLength: PVDesign.space2)
                    sourceDay
                }
                VStack(alignment: .leading, spacing: 4) {
                    caption.lineLimit(2)
                    sourceDay
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(briefDisabled)
        .help("See who's coming, related meetings and open to-dos")
        .accessibilityIdentifier("home-brief-open")
    }

    private var caption: some View {
        PVCardCaption(
            text: L10n.text("Brief · what they said last time"),
            systemImage: ChipLabel.generatedSymbol, tint: PVDesign.green)
    }

    @ViewBuilder
    private var sourceDay: some View {
        if let source {
            Text(source.dayAndLength)
                .font(.caption.monospacedDigit())
                .foregroundStyle(PVDesign.ink3)
                .lineLimit(1)
        }
    }

    /// The strip beside its shares when they fit, above them otherwise.
    private func stripRow(_ strip: VoiceStripColumns) -> some View {
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
            HomeBriefRowLayout(nameWidth: Self.nameWidth) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(VoicePalette.color(
                            page.tint(for: person.speakerID, isMe: person.isMe, in: meetingID),
                            colorScheme: colorScheme))
                        .frame(width: 10, height: 10)
                    Text(Self.name(person))
                        .font(.body.weight(.bold))
                        .foregroundStyle(PVDesign.ink)
                        .lineLimit(1)
                }
                .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    if line.kind == .quote {
                        Text(L10n.format("“%@”", line.text))
                            .pvDisplay(Self.quote)
                            .foregroundStyle(PVDesign.ink)
                    } else {
                        Text(line.text)
                            .font(.body.weight(.medium))
                            .foregroundStyle(PVDesign.ink)
                    }
                    if let meta = Self.meta(line) {
                        Text(PVFont.timeCoded(meta, time: Self.time(line)))
                            .font(.caption)
                            .foregroundStyle(PVDesign.ink3)
                    }
                }
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open the meeting at this moment")
        .accessibilityIdentifier("home-brief-person-\(person.speakerID.rawValue.uuidString)")
    }

    nonisolated static func name(_ person: MeetingBriefLines.Person) -> String {
        VoiceName.of(isMe: person.isMe, name: person.displayName, label: person.label)
    }

    /// "12:40 · still unresolved"; a line without transcript evidence has no time.
    nonisolated static func meta(
        _ line: MeetingBriefLines.Line, now: Date = Date(), calendar: Calendar = .current
    ) -> String? {
        let parts = [time(line), status(line.status, now: now, calendar: calendar)].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    nonisolated static func time(_ line: MeetingBriefLines.Line) -> String? {
        line.segmentID == nil ? nil : ClockFormat.mmss(line.time, locale: AppLanguage.current.locale)
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

/// A brief row: the name in its own column beside the line while the line keeps
/// a readable measure, above the line in a narrower card. Expects two subviews.
struct HomeBriefRowLayout: Layout {
    let nameWidth: CGFloat
    private static let spacing: CGFloat = 12
    private static let stackedSpacing: CGFloat = 4
    private static let minimumLineWidth: CGFloat = 200

    func isBeside(width: CGFloat) -> Bool {
        width - nameWidth - Self.spacing >= Self.minimumLineWidth
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? nameWidth + Self.spacing + Self.minimumLineWidth
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard subviews.count == 2 else { return [] }
        if isBeside(width: width) {
            let lineX = nameWidth + Self.spacing
            return [
                CGRect(x: 0, y: 0, width: nameWidth, height: height(subviews[0], width: nameWidth)),
                CGRect(x: lineX, y: 0, width: width - lineX, height: height(subviews[1], width: width - lineX))
            ]
        }
        let nameHeight = height(subviews[0], width: width)
        return [
            CGRect(x: 0, y: 0, width: width, height: nameHeight),
            CGRect(
                x: 0, y: nameHeight + Self.stackedSpacing,
                width: width, height: height(subviews[1], width: width))
        ]
    }

    private func height(_ subview: LayoutSubview, width: CGFloat) -> CGFloat {
        subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
    }
}
