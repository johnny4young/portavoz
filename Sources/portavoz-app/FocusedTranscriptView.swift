import PortavozCore
import SwiftUI

enum FocusedTranscriptMode: Equatable, Sendable {
    case playback
    case live
}

struct TranscriptFocusVisualStyle: Equatable, Sendable {
    let opacity: Double
    let scale: CGFloat
    let blurRadius: CGFloat
}

/// Pure visual policy shared by the view and characterization tests. Playback
/// keeps the released cylinder treatment; live captions keep a much wider
/// readable zone and become completely sharp while the user browses history.
enum TranscriptFocusVisualPolicy {
    static func style(
        distance: CGFloat,
        reach: CGFloat,
        mode: FocusedTranscriptMode,
        isFollowing: Bool
    ) -> TranscriptFocusVisualStyle {
        guard mode != .live || isFollowing else {
            return TranscriptFocusVisualStyle(opacity: 1, scale: 1, blurRadius: 0)
        }

        let safeReach = max(reach, 1)
        let deadzone: CGFloat
        let maximumFade: Double
        let maximumShrink: CGFloat
        let maximumBlur: CGFloat
        switch mode {
        case .playback:
            deadzone = 58
            maximumFade = 0.72
            maximumShrink = 0.10
            maximumBlur = 2
        case .live:
            deadzone = max(110, min(180, safeReach * 0.32))
            maximumFade = 0.48
            maximumShrink = 0.05
            maximumBlur = 0.65
        }
        let far = max(1, safeReach - deadzone)
        let progress = min(1, max(0, (distance - deadzone) / far))
        return TranscriptFocusVisualStyle(
            opacity: 1 - (maximumFade * Double(progress)),
            scale: 1 - (maximumShrink * progress),
            blurRadius: maximumBlur * progress)
    }
}

/// Pure reader-intent policy for the platforms without `onScrollPhaseChange`
/// (macOS 14, which the package still supports). Without a phase signal the
/// only evidence is the content offset itself, and our own recentering moves
/// that same offset — so travel is only read as intent once the programmatic
/// animation has settled, and only past a threshold that layout jitter
/// cannot reach.
enum TranscriptScrollIntentPolicy {
    /// Slightly longer than the 0.35 s recenter animation.
    static let settleWindow: TimeInterval = 0.45
    /// A row is ~40 pt tall; smaller travel is layout noise, not a reader.
    static let minimumTravel: CGFloat = 6
    /// Named space the offset is measured in. It lives here because a
    /// generic view cannot hold a static stored property.
    static let coordinateSpace = "focused-transcript-scroll"

    static func isReaderScroll(
        offsetDelta: CGFloat,
        secondsSinceProgrammaticScroll: TimeInterval
    ) -> Bool {
        guard secondsSinceProgrammaticScroll > settleWindow else { return false }
        return abs(offsetDelta) >= minimumTravel
    }
}

/// A Spotify-lyrics-style transcript: the active line stays centered while
/// the others carousel past. Playback always follows its active line. Live
/// recording follows the newest caption until the user scrolls, then yields
/// ownership until they explicitly choose "Jump to live".
struct FocusedTranscriptView<Row: View>: View {
    let segments: [TranscriptSegment]
    let activeID: TranscriptSegment.ID?
    var height: CGFloat = 440
    /// Where the focused line sits. `.center` for playback (past + future
    /// around it); lower (e.g. y ≈ 0.82) for live recording, where the new
    /// line is the frontier and older lines rise above it.
    var anchor: UnitPoint = .center
    /// A value that changes when the active line GROWS without changing id.
    var followSignal: Double = 0
    var mode = FocusedTranscriptMode.playback
    var scrollAccessibilityIdentifier: String?
    @ViewBuilder var row: (TranscriptSegment, Bool) -> Row

    @State private var isFollowing = true
    /// macOS 14 fallback state: when our own recentering last moved the
    /// offset, so its travel is not mistaken for the reader's.
    @State private var lastProgrammaticScroll = Date.distantPast

    var body: some View {
        let focusY = anchor.y * height
        let reach = max(focusY, height - focusY, 1)
        let visualMode = mode
        let following = isFollowing
        return ScrollViewReader { proxy in
            trackedScroll(
                identifiedScroll(
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 6) {
                            ForEach(segments) { segment in
                                row(segment, segment.id == activeID)
                                    .id(segment.id)
                                    .visualEffect { content, geometry in
                                        let midY = geometry.frame(
                                            in: .scrollView(axis: .vertical)
                                        ).midY
                                        let style = TranscriptFocusVisualPolicy.style(
                                            distance: abs(midY - focusY),
                                            reach: reach,
                                            mode: visualMode,
                                            isFollowing: following)
                                        return content
                                            .opacity(style.opacity)
                                            .scaleEffect(style.scale, anchor: .center)
                                            .blur(radius: style.blurRadius)
                                    }
                            }
                        }
                        // Pad so the first and last lines can reach the focus line.
                        .padding(.top, focusY)
                        .padding(.bottom, height - focusY)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background { scrollOffsetReader() }
                    }
                    .coordinateSpace(name: TranscriptScrollIntentPolicy.coordinateSpace)),
                onUserScroll: { isFollowing = false })
            .frame(height: height)
            .overlay(alignment: .bottomTrailing) {
                if mode == .live, !isFollowing {
                    Button {
                        isFollowing = true
                        recenter(proxy, activeID)
                    } label: {
                        Label("Jump to live", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("recording-jump-to-live")
                    .padding(12)
                }
            }
            .onChange(of: activeID) { _, id in
                guard followsActiveLine else { return }
                recenter(proxy, id)
            }
            .onChange(of: followSignal) { _, _ in
                guard followsActiveLine else { return }
                recenter(proxy, activeID)
            }
            .onAppear { recenter(proxy, activeID, animated: false) }
        }
    }

    private var followsActiveLine: Bool {
        mode == .playback || isFollowing
    }

    @ViewBuilder
    private func identifiedScroll<Content: View>(_ content: Content) -> some View {
        if let scrollAccessibilityIdentifier {
            content.accessibilityIdentifier(scrollAccessibilityIdentifier)
        } else {
            content
        }
    }

    @ViewBuilder
    private func trackedScroll<Content: View>(
        _ content: Content,
        onUserScroll: @escaping () -> Void
    ) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollPhaseChange { _, phase in
                guard mode == .live, phase == .interacting else { return }
                onUserScroll()
            }
        } else {
            // macOS 14 has no scroll-phase signal; `scrollOffsetReader`
            // inside the content supplies the intent instead.
            content
        }
    }

    /// The macOS 14 half of reader-owned scrolling. It rides INSIDE the
    /// scrolled content, so its frame in the scroll coordinate space is the
    /// content offset. Rapid captions keep refreshing the settle window, so
    /// on macOS 14 a scroll made between two fast recenters can be missed —
    /// the reader simply scrolls again, which beats macOS 14 never yielding
    /// ownership at all.
    @ViewBuilder
    private func scrollOffsetReader() -> some View {
        if #unavailable(macOS 15.0) {
            GeometryReader { geometry in
                Color.clear
                    .onChange(
                        of: geometry.frame(
                            in: .named(TranscriptScrollIntentPolicy.coordinateSpace)
                        ).minY
                    ) { previous, current in
                        guard mode == .live, isFollowing else { return }
                        guard TranscriptScrollIntentPolicy.isReaderScroll(
                            offsetDelta: current - previous,
                            secondsSinceProgrammaticScroll:
                                Date().timeIntervalSince(lastProgrammaticScroll))
                        else { return }
                        isFollowing = false
                    }
            }
        }
    }

    private func recenter(
        _ proxy: ScrollViewProxy,
        _ id: TranscriptSegment.ID?,
        animated: Bool = true
    ) {
        guard let id else { return }
        // Stamped before the move so the macOS 14 offset reader attributes
        // the travel that follows to us, not to the reader.
        lastProgrammaticScroll = Date()
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        } else {
            proxy.scrollTo(id, anchor: anchor)
        }
    }
}
