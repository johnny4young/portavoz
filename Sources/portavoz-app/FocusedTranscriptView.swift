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
    /// Where the focused line sits. `.center` for playback (past + future
    /// around it); lower (e.g. y ≈ 0.82) for live recording, where the new
    /// line is the frontier and older lines rise and fade above it.
    var anchor: UnitPoint = .center
    /// A value that changes when the active line GROWS without changing id
    /// (the live caption expanding) — re-centers so the frontier stays put.
    var followSignal: Double = 0
    @ViewBuilder var row: (TranscriptSegment, Bool) -> Row

    private let space = "focused-transcript"

    var body: some View {
        let focusY = anchor.y * height
        let reach = max(focusY, height - focusY, 1)
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(segments) { segment in
                        row(segment, segment.id == activeID)
                            .id(segment.id)
                            .visualEffect { content, geometry in
                                // Distance of this row's center from the
                                // focus line, 0…1 — drives the fade, shrink
                                // and blur of the cylinder. A dead zone keeps
                                // the focused line AND the one right above/below
                                // it fully sharp and readable; only lines
                                // further out fade.
                                let midY = geometry.frame(in: .named(space)).midY
                                let deadzone: CGFloat = 58
                                let far = max(1, reach - deadzone)
                                let t: CGFloat = min(1, max(0, (abs(midY - focusY) - deadzone) / far))
                                let opacity: Double = 1.0 - (0.72 * Double(t))
                                let scale: CGFloat = 1.0 - (0.10 * t)
                                let blurRadius: CGFloat = 2.0 * t
                                return
                                    content
                                    .opacity(opacity)
                                    .scaleEffect(scale, anchor: .center)
                                    .blur(radius: blurRadius)
                            }
                    }
                }
                // Pad so the first and last lines can reach the focus line.
                .padding(.top, focusY)
                .padding(.bottom, height - focusY)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(.named(space))
            .frame(height: height)
            .onChange(of: activeID) { _, id in recenter(proxy, id) }
            .onChange(of: followSignal) { _, _ in recenter(proxy, activeID) }
            .onAppear { recenter(proxy, activeID, animated: false) }
        }
    }

    private func recenter(_ proxy: ScrollViewProxy, _ id: TranscriptSegment.ID?, animated: Bool = true) {
        guard let id else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: anchor) }
        } else {
            proxy.scrollTo(id, anchor: anchor)
        }
    }
}
