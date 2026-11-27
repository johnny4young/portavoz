import ApplicationKit
import PortavozCore
import SwiftUI

/// Lazy, synchronized transcript rows inside the meeting page's scroll. While
/// audio plays and the transcript is on screen, the page follows the active
/// row; an explicit seek or citation brings its row into view. Playback never
/// pulls the page away from the header or summary the reader is on.
/// Active-row lookup stays logarithmic instead of scanning every row at the
/// playback refresh cadence. On a page wide enough for the margin, a line's
/// decisions and commitments sit beside it; otherwise they fold under it.
struct TranscriptSegmentsView: View {
    let content: MeetingTranscriptContent
    let speakers: [Speaker]
    let voiceCast: VoiceCast
    let player: MeetingPlaybackSession?
    let focusedRowID: UUID?
    let revealCount: Int
    var performanceScrollEnabled = false
    let onSeek: (TimeInterval) -> Void
    let onRenameTap: (Speaker) -> Void
    let canCorrect: (MeetingTranscriptContent.Row) -> Bool
    let onCorrect: (MeetingTranscriptContent.Row) -> Void
    /// The section's measured width; zero until measured.
    let pageWidth: CGFloat
    let margin: MeetingMarginNotesContext?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didStartPerformanceScroll = false
    @State private var isOnScreen = false

    private var marginWidth: CGFloat? { MeetingDetailPageMetrics.marginWidth(forPageWidth: pageWidth) }
    private var readingWidth: CGFloat { MeetingDetailPageMetrics.readingWidth(forPageWidth: pageWidth) }
    private var isNarrow: Bool { MeetingDetailPageMetrics.usesInlineGutter(width: readingWidth) }

    private var activeRowID: UUID? {
        guard let player else { return focusedRowID }
        return content.activeRowID(at: player.currentTime)
    }

    var body: some View {
        let activeRowID = activeRowID
        ScrollViewReader { proxy in
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(content.readingItems) { item in
                    let correctableRow = correctableRow(item)
                    withNotes(item, reservesCorrectionSpace: correctableRow != nil) {
                        ZStack(alignment: .trailing) {
                            itemView(
                                item,
                                isActive: item.id == activeRowID.map { .row($0) },
                                reservesCorrectionSpace: correctableRow != nil)
                            if let correctableRow { correctionAction(for: correctableRow) }
                        }
                    }
                    .id(item.id)
                }
            }
            // Rows inset for the active outline; the stack gives that back so
            // turn text shares the standfirst's edge.
            .padding(.horizontal, -TranscriptReadingLayout.outlineOverhang)
            // A sliver under the summary is not reading the transcript; follow
            // only once it reaches the upper half of the page.
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.bounds(of: .scrollView(axis: .vertical)).map { visible in
                    let frame = proxy.frame(in: .local)
                    return frame.minY <= visible.midY && frame.maxY >= visible.minY
                } ?? true
            } action: { isOnScreen = $0 }
            .onChange(of: activeRowID) { _, id in
                guard player?.isPlaying == true, isOnScreen, let id else { return }
                scroll(proxy, to: content.readingKey(following: id))
            }
            // Switching layouts changes row heights, so recenter the active row.
            .onChange(of: isNarrow) { _, _ in
                guard player?.isPlaying == true, isOnScreen, let activeRowID else { return }
                scroll(proxy, to: content.readingKey(following: activeRowID))
            }
            .onChange(of: revealCount) { _, _ in
                guard let focusedRowID else { return }
                scroll(proxy, to: content.readingKey(following: focusedRowID))
            }
            .task(id: performanceScrollEnabled ? content.rows.count : 0) {
                runPerformanceScrollIfRequested(proxy)
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: TranscriptReadingItem.Key) {
        let interval = MeetingDetailPerformanceTrace.beginTranscriptScroll()
        PVMotion.perform(.easeInOut(duration: 0.25), reduceMotion: reduceMotion) {
            proxy.scrollTo(id, anchor: .center)
        } completion: {
            MeetingDetailPerformanceTrace.endTranscriptScroll(interval)
        }
    }

    private func runPerformanceScrollIfRequested(_ proxy: ScrollViewProxy) {
        guard MeetingDetailPerformanceTrace.isEnabled,
              performanceScrollEnabled,
              !didStartPerformanceScroll,
              content.rows.count >= 4
        else { return }
        didStartPerformanceScroll = true
        let targetOffsets = [3, 1, 2, 0, 3].map {
            min(content.rows.count - 1, content.rows.count * $0 / 4)
        }
        let targets = targetOffsets.map { TranscriptReadingItem.Key.row(content.rows[$0].id) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for target in targets {
                scroll(proxy, to: target)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// The inset leaves room for the active outline, which overhangs its row.
    private func itemView(
        _ item: TranscriptReadingItem,
        isActive: Bool,
        reservesCorrectionSpace: Bool
    ) -> some View {
        Group {
            switch item {
            case .chapter(let chapter):
                TranscriptChapterRow(
                    chapter: chapter,
                    isNarrow: isNarrow,
                    canSeek: player != nil,
                    onSeek: onSeek)
            case let .row(row, startsTurn):
                MeetingTranscriptRowView(
                    row: row,
                    startsTurn: startsTurn,
                    speaker: speakers.first { $0.id == row.speakerID },
                    cast: voiceCast,
                    isActive: isActive,
                    isNarrow: isNarrow,
                    canSeek: player != nil,
                    onSeek: onSeek,
                    onRenameTap: onRenameTap,
                    reservesCorrectionSpace: reservesCorrectionSpace)
            }
        }
        .padding(.horizontal, TranscriptReadingLayout.outlineOverhang)
    }

    /// The item in the reading column, with its line's notes in the margin
    /// beside it or folded under the text.
    @ViewBuilder
    private func withNotes(
        _ item: TranscriptReadingItem,
        reservesCorrectionSpace: Bool,
        @ViewBuilder line: () -> some View
    ) -> some View {
        let overhang = TranscriptReadingLayout.outlineOverhang
        // Unmeasured, the line takes the proposed width rather than none.
        let lineWidth = pageWidth > 0 ? readingWidth + 2 * overhang : nil
        if let margin, case .row(let row, _) = item, case let notes = margin.notes.notes(forRow: row.id),
           !notes.isEmpty {
            if let marginWidth {
                HStack(alignment: .top, spacing: MeetingDetailPageMetrics.gap - overhang) {
                    line().frame(width: lineWidth)
                    MeetingMarginNotesColumn(notes: notes, context: margin)
                        .frame(width: marginWidth)
                }
                .padding(.trailing, overhang)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    line()
                    MeetingMarginNotesColumn(notes: notes, context: margin)
                        .padding(.leading, overhang + (isNarrow ? 0 : TranscriptReadingLayout.textIndent))
                        .padding(
                            .trailing,
                            overhang + (reservesCorrectionSpace ? TranscriptReadingLayout.correctionReserve : 0))
                        .padding(.bottom, 8)
                }
            }
        } else {
            line()
                .frame(width: lineWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func correctableRow(_ item: TranscriptReadingItem) -> MeetingTranscriptContent.Row? {
        guard case .row(let row, _) = item, canCorrect(row) else { return nil }
        return row
    }

    private func correctionAction(for row: MeetingTranscriptContent.Row) -> some View {
        Button {
            onCorrect(row)
        } label: {
            Image(systemName: "pencil")
                .imageScale(.small)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Correct transcript line")
        .accessibilityLabel("Correct transcript row")
        .accessibilityIdentifier(correctionIdentifier(for: row))
        .padding(.trailing, 8)
    }

    private func correctionIdentifier(
        for row: MeetingTranscriptContent.Row
    ) -> String {
        guard let sourceID = row.sourceSegmentIDs.first else {
            return "transcript-correct-\(row.id.uuidString)"
        }
        let visibleCount = content.rows.lazy.filter {
            $0.sourceSegmentIDs.contains(sourceID)
        }.count
        if visibleCount == 1 {
            return "transcript-correct-\(sourceID.uuidString)"
        }
        return "transcript-correct-\(sourceID.uuidString)-\(row.id.uuidString)"
    }
}

/// The board's two transcript layouts: speaker and time in a left margin, or
/// above each turn once the column is too narrow for that margin.
private enum TranscriptReadingLayout {
    static let marginWidth: CGFloat = 118
    /// The summary's gutter and gap, so turn text and the standfirst align.
    static let marginGap: CGFloat = 22
    static let outlineOverhang: CGFloat = 12
    /// Where turn text starts when the speaker sits in the left margin.
    static let textIndent: CGFloat = marginWidth + marginGap
    /// Room kept for the correction pencil at the row's trailing edge.
    static let correctionReserve: CGFloat = 36
}

/// A chapter heading inside the transcript: its time code and its title.
private struct TranscriptChapterRow: View {
    let chapter: MeetingTranscriptContent.Chapter
    let isNarrow: Bool
    let canSeek: Bool
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        // Without audio the heading is plain text: a disabled button would dim the title.
        Group {
            if canSeek {
                Button {
                    onSeek(chapter.startTime)
                } label: {
                    heading
                }
                .buttonStyle(.plain)
            } else {
                heading
            }
        }
        .padding(.top, 10)
        .help(canSeek
            ? L10n.text("Jump to this moment")
            : L10n.text("Jumping needs audio, and this meeting has none"))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("transcript-chapter-\(Int(chapter.startTime))")
    }

    /// Wide, the time sits in the speaker margin; narrow, it follows the
    /// title the way a turn's time follows its speaker, so title and turn
    /// text share one edge.
    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: isNarrow ? 10 : TranscriptReadingLayout.marginGap) {
            if !isNarrow {
                time.frame(width: TranscriptReadingLayout.marginWidth, alignment: .trailing)
            }
            Text(chapter.title)
                .pvDisplay(isNarrow ? .sectionCompact : .section)
                .foregroundStyle(PVDesign.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if isNarrow { time }
            Spacer(minLength: 0)
        }
        .padding(.top, 11)
        .padding(.bottom, 4)
        .overlay(alignment: .top) {
            Rectangle().fill(PVDesign.line2).frame(height: 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var time: some View {
        Text(ClockFormat.mmss(chapter.startTime))
            .font(PVFont.timeCode(.caption))
            .foregroundStyle(PVDesign.ink3)
            .fixedSize()
    }
}

/// One correction-ready reading row. Its stable identity belongs to the
/// composed input; source evidence coordinates remain outside presentation.
private struct MeetingTranscriptRowView: View {
    let row: MeetingTranscriptContent.Row
    let startsTurn: Bool
    let speaker: Speaker?
    let cast: VoiceCast
    let isActive: Bool
    let isNarrow: Bool
    let canSeek: Bool
    let onSeek: (TimeInterval) -> Void
    let onRenameTap: (Speaker) -> Void
    let reservesCorrectionSpace: Bool
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    var body: some View {
        Group {
            if isNarrow {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) { turnHeader }
                    text(size: 14.5)
                }
                .background { if isActive { activeOutline } }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: TranscriptReadingLayout.marginGap) {
                    VStack(alignment: .trailing, spacing: 2) { turnHeader }
                        .frame(width: TranscriptReadingLayout.marginWidth, alignment: .trailing)
                    text(size: 15)
                        .background { if isActive { activeOutline } }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.trailing, reservesCorrectionSpace ? TranscriptReadingLayout.correctionReserve : 0)
        .contentShape(Rectangle())
        .onTapGesture { if canSeek { onSeek(row.startTime) } }
        .accessibilityElement(children: .contain)
        // Continuation lines show no name, so VoiceOver still hears whose line it is.
        .accessibilityLabel(voiceName)
        .accessibilityIdentifier("transcript-segment-\(row.id.uuidString)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var voiceName: String {
        speaker.map { VoiceName.of(isMe: $0.isMe, name: VoiceCast.name($0.displayName), label: $0.label) } ?? "?"
    }

    @ViewBuilder
    private var turnHeader: some View {
        if startsTurn { speakerButton }
        Button {
            onSeek(row.startTime)
        } label: {
            Text(ClockFormat.mmss(row.startTime))
                .font(PVFont.timeCode(.caption2))
                .foregroundStyle(PVDesign.ink3)
        }
        .buttonStyle(.plain)
        .disabled(!canSeek)
        .help("Jump to this moment")
    }

    /// The voice's tone is a fill, so its name reads in ink beside a dot; you
    /// read in amber ink.
    private var speakerButton: some View {
        let isNamed = speaker.map { $0.isMe || VoiceCast.name($0.displayName) != nil } ?? false
        let name = voiceName
        return Button {
            if let speaker { onRenameTap(speaker) }
        } label: {
            HStack(spacing: 6) {
                VoiceDot(tint: speaker.map { cast.tint(for: $0) } ?? .grey, size: 7, isOpen: !isNamed)
                Text(name)
                    .font(.system(size: 12.5 * textScale, weight: .bold))
                    .foregroundStyle(speaker?.isMe == true ? PVDesign.youInk : isNamed ? PVDesign.ink : PVDesign.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .buttonStyle(.plain)
        .disabled(speaker == nil)
        .help("Rename…")
        .accessibilityLabel(name)
        .accessibilityValue(speaker.map(VoiceName.linkState) ?? "")
        .accessibilityIdentifier("transcript-speaker-\(row.id.uuidString)")
    }

    @ViewBuilder
    private func text(size: CGFloat) -> some View {
        // Selectable text swallows clicks on macOS, so with audio a click
        // on the words jumps there instead of starting a selection.
        let words = Text(row.text)
            .font(.system(size: size * textScale))
            .lineSpacing(size * textScale * 0.25)
            .foregroundStyle(PVDesign.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
        if canSeek {
            words
        } else {
            words.textSelection(.enabled)
        }
    }

    /// The turn under the playhead is outlined instead of tinted; the outline
    /// overhangs its content so rows keep their spacing.
    private var activeOutline: some View {
        RoundedRectangle(cornerRadius: PVDesign.radiusSmall)
            .fill(PVDesign.raise)
            .overlay(RoundedRectangle(cornerRadius: PVDesign.radiusSmall).strokeBorder(PVDesign.line2, lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
            .padding(.horizontal, -TranscriptReadingLayout.outlineOverhang)
            .padding(.vertical, -5)
    }
}
