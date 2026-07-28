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

@available(macOS 15.0, *)
enum LiveTranscriptScrollOwnershipPolicy {
    static func shouldYieldFollow(for phase: ScrollPhase) -> Bool {
        switch phase {
        case .tracking, .interacting, .decelerating:
            true
        case .idle, .animating:
            false
        }
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
                        .background {
                            if #available(macOS 15.0, *) {
                                EmptyView()
                            } else {
                                LegacyScrollInteractionTracker {
                                    guard mode == .live else { return }
                                    isFollowing = false
                                }
                                .frame(width: 0, height: 0)
                            }
                        }
                    }),
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
                guard mode == .live,
                      LiveTranscriptScrollOwnershipPolicy.shouldYieldFollow(for: phase)
                else { return }
                onUserScroll()
            }
        } else {
            // The document-scoped AppKit bridge inside the content owns the
            // macOS 14 user-only live-scroll signal.
            content
        }
    }

    private func recenter(
        _ proxy: ScrollViewProxy,
        _ id: TranscriptSegment.ID?,
        animated: Bool = true
    ) {
        guard let id else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        } else {
            proxy.scrollTo(id, anchor: anchor)
        }
    }
}
