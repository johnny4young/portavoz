import PortavozCore
import SwiftUI

/// A Spotify-lyrics-style transcript: the active line stays centered while
/// the others carousel past, fading and shrinking toward the edges (a
/// "paper cylinder" feel). It lives in a FIXED-height viewport, so a change
/// in `activeID` re-centers WITHIN the box — the surrounding page never
/// jumps. Manual scroll still works to read ahead; the next `activeID`
/// change gently re-centers. Reused by the meeting detail (playback) and
/// live recording (newest caption).
struct FocusedTranscriptView<Row: View>: View {
    let segments: [TranscriptSegment]
    let activeID: TranscriptSegment.ID?
    var height: CGFloat = 440
    @ViewBuilder var row: (TranscriptSegment, Bool) -> Row

    private let space = "focused-transcript"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(segments) { segment in
                        row(segment, segment.id == activeID)
                            .id(segment.id)
                            .visualEffect { content, geometry in
                                // Distance of this row's center from the
                                // viewport center, 0…1 — drives the fade,
                                // shrink and blur of the cylinder.
                                let midY = geometry.frame(in: .named(space)).midY
                                let center = height / 2
                                let t = min(1, abs(midY - center) / max(center, 1))
                                return
                                    content
                                    .opacity(1 - 0.72 * t)
                                    .scaleEffect(1 - 0.10 * t, anchor: .center)
                                    .blur(radius: 2.2 * t)
                            }
                    }
                }
                // Half a viewport of padding top and bottom so the first and
                // last lines can reach the center.
                .padding(.vertical, height / 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(.named(space))
            .frame(height: height)
            .scrollIndicators(.hidden)
            .onChange(of: activeID) { _, id in recenter(proxy, id) }
            .onAppear { recenter(proxy, activeID, animated: false) }
        }
    }

    private func recenter(_ proxy: ScrollViewProxy, _ id: TranscriptSegment.ID?, animated: Bool = true)
    {
        guard let id else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}
