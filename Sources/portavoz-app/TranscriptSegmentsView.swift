import ApplicationKit
import PortavozCore
import SwiftUI

/// A lazy, synchronized viewport over an already composed transcript value.
/// Playhead updates invalidate only this subtree, and active-row lookup stays
/// logarithmic instead of scanning every row at the playback refresh cadence.
struct TranscriptSegmentsView: View {
    let content: MeetingTranscriptContent
    let speakers: [Speaker]
    let voiceCast: VoiceCast
    let player: MeetingPlaybackSession?
    let focusedRowID: UUID?
    var performanceScrollEnabled = false
    let onSeek: (TimeInterval) -> Void
    let onRenameTap: (Speaker) -> Void
    let canCorrect: (MeetingTranscriptContent.Row) -> Bool
    let onCorrect: (MeetingTranscriptContent.Row) -> Void
    /// Height of the lyrics carousel when there's audio — the detail sizes it
    /// to the available space so the docked player is never pushed off.
    var carouselHeight: CGFloat = 440

    @State private var didStartPerformanceScroll = false
    @State private var isNarrow = false

    private var activeRowID: UUID? {
        guard let player else { return nil }
        return content.activeRowID(at: player.currentTime)
    }

    var body: some View {
        transcript
            .onGeometryChange(for: Bool.self) { proxy in
                TranscriptReadingLayout.isNarrow(width: proxy.size.width)
            } action: { isNarrow = $0 }
    }

    @ViewBuilder
    private var transcript: some View {
        if player != nil {
            // Playback always follows the synchronized row inside this
            // viewport; it never moves the surrounding Meeting Detail chrome.
            let activeRowID = activeRowID
            FocusedTranscriptView(
                segments: content.readingItems,
                activeID: activeRowID.map(content.readingKey(following:)),
                height: carouselHeight,
                // Switching layouts changes row heights, so recenter the active row.
                followSignal: isNarrow ? 1 : 0,
                scrollAccessibilityIdentifier: "detail-transcript-scroll"
            ) { item, _ in
                itemView(item, isActive: item.id == activeRowID.map { .row($0) })
            } accessory: { item, _ in
                correctionAction(for: item)
            }
        } else {
            textOnlyTranscript
        }
    }

    private var textOnlyTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(content.readingItems) { item in
                        ZStack(alignment: .trailing) {
                            itemView(item, isActive: item.id == focusedRowID.map { .row($0) })
                            correctionAction(for: item)
                        }
                        .id(item.id)
                    }
                }
            }
            .accessibilityIdentifier("detail-transcript-scroll")
            .onChange(of: focusedRowID) { _, id in
                guard let id else { return }
                scroll(proxy, to: .row(id))
            }
            .task(id: performanceScrollEnabled ? content.rows.count : 0) {
                runPerformanceScrollIfRequested(proxy)
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: TranscriptReadingItem.Key) {
        let interval = MeetingDetailPerformanceTrace.beginTranscriptScroll()
        withAnimation(
            .easeInOut(duration: 0.25),
            completionCriteria: .logicallyComplete
        ) {
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
    private func itemView(_ item: TranscriptReadingItem, isActive: Bool) -> some View {
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
                    reservesCorrectionSpace: canCorrect(row))
            }
        }
        .padding(.horizontal, TranscriptReadingLayout.outlineOverhang)
    }

    @ViewBuilder
    private func correctionAction(for item: TranscriptReadingItem) -> some View {
        if case .row(let row, _) = item, canCorrect(row) {
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
    static let marginGap: CGFloat = 26
    static let outlineOverhang: CGFloat = 12
    static let narrowBelow: CGFloat = 520

    static func isNarrow(width: CGFloat) -> Bool { width > 0 && width < narrowBelow }
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

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: isNarrow ? 12 : TranscriptReadingLayout.marginGap) {
            Text(ClockFormat.mmss(chapter.startTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(PVDesign.ink3)
                .frame(width: isNarrow ? nil : TranscriptReadingLayout.marginWidth, alignment: .trailing)
            Text(chapter.title)
                .pvDisplay(isNarrow ? .sectionCompact : .section)
                .foregroundStyle(PVDesign.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
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
        .padding(.trailing, reservesCorrectionSpace ? 36 : 0)
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
                .font(.system(.caption2, design: .monospaced))
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
