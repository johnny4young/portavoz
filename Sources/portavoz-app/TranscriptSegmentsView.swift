import ApplicationKit
import PortavozCore
import SwiftUI

/// A lazy, synchronized viewport over an already composed transcript value.
/// Playhead updates invalidate only this subtree, and active-row lookup stays
/// logarithmic instead of scanning every row at the playback refresh cadence.
struct TranscriptSegmentsView: View {
    let content: MeetingTranscriptContent
    let speakers: [Speaker]
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

    private var activeRowID: MeetingTranscriptContent.Row.ID? {
        guard let player else { return nil }
        return content.activeRowID(at: player.currentTime)
    }

    var body: some View {
        if player != nil {
            // Playback always follows the synchronized row inside this
            // viewport; it never moves the surrounding Meeting Detail chrome.
            FocusedTranscriptView(
                segments: content.rows,
                activeID: activeRowID,
                height: carouselHeight
            ) { row, isActive in
                transcriptRow(row, isActive: isActive)
            }
        } else {
            textOnlyTranscript
        }
    }

    private var textOnlyTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(content.rows) { row in
                        transcriptRow(row, isActive: row.id == focusedRowID)
                            .id(row.id)
                    }
                }
            }
            .onChange(of: focusedRowID) { _, id in
                guard let id else { return }
                scroll(proxy, to: id)
            }
            .task(id: performanceScrollEnabled ? content.rows.count : 0) {
                runPerformanceScrollIfRequested(proxy)
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: UUID) {
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
        let targets = targetOffsets.map { content.rows[$0].id }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for target in targets {
                scroll(proxy, to: target)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func transcriptRow(
        _ row: MeetingTranscriptContent.Row,
        isActive: Bool
    ) -> some View {
        MeetingTranscriptRowView(
            row: row,
            speaker: speakers.first { $0.id == row.speakerID },
            cast: speakers,
            isActive: isActive,
            canSeek: player != nil,
            onSeek: onSeek,
            onRenameTap: onRenameTap,
            canCorrect: canCorrect,
            onCorrect: onCorrect,
            correctionIdentifier: correctionIdentifier(for: row))
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

/// One correction-ready reading row. Its stable identity belongs to the
/// composed input; source evidence coordinates remain outside presentation.
private struct MeetingTranscriptRowView: View {
    let row: MeetingTranscriptContent.Row
    let speaker: Speaker?
    let cast: [Speaker]
    let isActive: Bool
    let canSeek: Bool
    let onSeek: (TimeInterval) -> Void
    let onRenameTap: (Speaker) -> Void
    let canCorrect: (MeetingTranscriptContent.Row) -> Bool
    let onCorrect: (MeetingTranscriptContent.Row) -> Void
    let correctionIdentifier: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                onSeek(row.startTime)
            } label: {
                Text(clock(row.startTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(
                        isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: 44, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .disabled(!canSeek)
            .help("Jump to this moment")
            SpeakerPill(
                speaker: speaker,
                cast: cast,
                onRename: onRenameTap)
            Text(row.text)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if canCorrect(row) {
                Button {
                    onCorrect(row)
                } label: {
                    Image(systemName: "pencil")
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
                .help("Correct transcript line")
                .accessibilityLabel("Correct transcript row")
                .accessibilityIdentifier(correctionIdentifier)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(
            isActive ? PVDesign.accent.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcript-segment-\(row.id.uuidString)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
