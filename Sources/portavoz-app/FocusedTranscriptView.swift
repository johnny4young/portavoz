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

enum TranscriptFollowOwnershipPolicy {
    static func followsActiveLine(
        mode: FocusedTranscriptMode,
        isFollowingLive: Bool
    ) -> Bool {
        mode == .playback || isFollowingLive
    }

    @available(macOS 15.0, *)
    static func shouldYieldFollow(
        mode: FocusedTranscriptMode,
        for phase: ScrollPhase
    ) -> Bool {
        guard mode == .live else { return false }
        switch phase {
        case .tracking, .interacting, .decelerating:
            return true
        case .idle, .animating:
            return false
        }
    }
}

/// A Spotify-lyrics-style transcript: the active line stays centered while
/// the others carousel past. Playback always follows its active line. Live
/// recording follows the newest caption until the user scrolls, then yields
/// ownership until they explicitly choose "Jump to live".
struct FocusedTranscriptView<
    Item: Identifiable,
    Row: View,
    Accessory: View
>: View where Item.ID: Hashable {
    let segments: [Item]
    let activeID: Item.ID?
    var height: CGFloat
    /// Where the focused line sits. `.center` for playback (past + future
    /// around it); lower (e.g. y ≈ 0.82) for live recording, where the new
    /// line is the frontier and older lines rise above it.
    var anchor: UnitPoint
    /// A value that changes when the active line GROWS without changing id.
    var followSignal: Double
    var mode: FocusedTranscriptMode
    var scrollAccessibilityIdentifier: String?
    @ViewBuilder var row: (Item, Bool) -> Row
    /// Interactive row chrome stays outside the presentation-only focus
    /// transform so hit testing continues to use the control's real frame.
    @ViewBuilder var accessory: (Item, Bool) -> Accessory

    @State private var isFollowing = true

    init(
        segments: [Item],
        activeID: Item.ID?,
        height: CGFloat = 440,
        anchor: UnitPoint = .center,
        followSignal: Double = 0,
        mode: FocusedTranscriptMode = .playback,
        scrollAccessibilityIdentifier: String? = nil,
        @ViewBuilder row: @escaping (Item, Bool) -> Row,
        @ViewBuilder accessory: @escaping (Item, Bool) -> Accessory
    ) {
        self.segments = segments
        self.activeID = activeID
        self.height = height
        self.anchor = anchor
        self.followSignal = followSignal
        self.mode = mode
        self.scrollAccessibilityIdentifier = scrollAccessibilityIdentifier
        self.row = row
        self.accessory = accessory
    }

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
                                let isActive = segment.id == activeID
                                ZStack(alignment: .trailing) {
                                    row(segment, isActive)
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
                                    accessory(segment, isActive)
                                }
                                .id(segment.id)
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
        TranscriptFollowOwnershipPolicy.followsActiveLine(
            mode: mode,
            isFollowingLive: isFollowing)
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
                guard TranscriptFollowOwnershipPolicy.shouldYieldFollow(
                    mode: mode,
                    for: phase)
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
        _ id: Item.ID?,
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

extension FocusedTranscriptView where Accessory == EmptyView {
    init(
        segments: [Item],
        activeID: Item.ID?,
        height: CGFloat = 440,
        anchor: UnitPoint = .center,
        followSignal: Double = 0,
        mode: FocusedTranscriptMode = .playback,
        scrollAccessibilityIdentifier: String? = nil,
        @ViewBuilder row: @escaping (Item, Bool) -> Row
    ) {
        self.init(
            segments: segments,
            activeID: activeID,
            height: height,
            anchor: anchor,
            followSignal: followSignal,
            mode: mode,
            scrollAccessibilityIdentifier: scrollAccessibilityIdentifier,
            row: row,
            accessory: { _, _ in EmptyView() })
    }
}
