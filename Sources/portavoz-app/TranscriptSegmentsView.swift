import ApplicationKit
import PortavozCore
import SwiftUI

/// The transcript with a synchronized highlight (M11). Its own View so the
/// playhead moving only re-renders here, not the summary/header above. The
/// timestamp doubles as a "jump here" button, leaving the text selectable.
struct TranscriptSegmentsView: View {
    let segments: [TranscriptSegment]
    let speakers: [Speaker]
    let player: MeetingPlaybackSession?
    let focusedSegmentID: UUID?
    let onSeek: (TimeInterval) -> Void
    let onRenameTap: (Speaker) -> Void
    /// Height of the lyrics carousel when there's audio — the detail sizes it
    /// to the available space so the docked player is never pushed off.
    var carouselHeight: CGFloat = 440

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
            FocusedTranscriptView(
                segments: segments, activeID: activeSegmentID, height: carouselHeight
            ) { segment, isActive in
                row(segment, isActive: isActive)
            }
        } else {
            // Text-only meetings own their scroll viewport too, so a cited
            // source can be focused without moving unrelated page chrome.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(segments) { segment in
                            row(segment, isActive: segment.id == focusedSegmentID)
                                .id(segment.id)
                        }
                    }
                }
                .onChange(of: focusedSegmentID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
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
            isActive ? PVDesign.accent.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcript-segment-\(segment.id.uuidString)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
