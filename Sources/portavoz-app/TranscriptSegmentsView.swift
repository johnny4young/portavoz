import AudioPlaybackKit
import PortavozCore
import SwiftUI

/// The transcript with a synchronized highlight (M11). Its own View so the
/// playhead moving only re-renders here, not the summary/header above. The
/// timestamp doubles as a "jump here" button, leaving the text selectable.
struct TranscriptSegmentsView: View {
    let segments: [TranscriptSegment]
    let speakers: [Speaker]
    let player: MeetingPlayer?
    let onSeek: (TimeInterval) -> Void
    let onRenameTap: (Speaker) -> Void

    /// The segment under the playhead: the one whose range contains the
    /// current time, or the last one that already started (so a gap between
    /// segments keeps the previous line lit).
    private var activeSegmentID: TranscriptSegment.ID? {
        guard let player else { return nil }
        let now = player.currentTime
        return segments.last(where: { $0.startTime <= now && now < $0.endTime })?.id
            ?? segments.last(where: { $0.startTime <= now })?.id
    }

    var body: some View {
        if player != nil {
            // With audio, the transcript is a Spotify-lyrics carousel: the
            // spoken line stays centered inside its own viewport, so seeking
            // moves the transcript, never the whole page.
            FocusedTranscriptView(segments: segments, activeID: activeSegmentID) { segment, isActive in
                row(segment, isActive: isActive)
            }
        } else {
            // No audio to follow — a plain readable list scrolling with the
            // page. Lazy: a long meeting has thousands of rows.
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(segments) { segment in
                    row(segment, isActive: false)
                }
            }
        }
    }

    private func row(_ segment: TranscriptSegment, isActive: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                onSeek(segment.startTime)
            } label: {
                Text(clock(segment.startTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: 44, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .disabled(player == nil)
            .help("Jump to this moment")
            SpeakerPill(
                speaker: speakers.first { $0.id == segment.speakerID },
                cast: speakers,
                onRename: onRenameTap)
            Text(segment.text)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(
            isActive ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6))
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
