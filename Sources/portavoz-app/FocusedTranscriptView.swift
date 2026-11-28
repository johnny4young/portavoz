import SwiftUI

enum FocusedTranscriptMode: Equatable, Sendable {
    case playback
    case live
}

/// Pure visual policy shared by the view and characterization tests. Live
/// captions dim line by line above the newest one and become completely
/// sharp while the user browses history; playback stays flat. Only opacity
/// changes, so Reduce Motion keeps the same treatment.
enum TranscriptFocusVisualPolicy {
    /// The dimmest a live caption gets: ink at this opacity still reads at
    /// 4.5:1 on paper in light and dark.
    static let liveFloor = 0.6
    /// The newest line stays at full ink within this distance of the focus.
    static let liveDeadzone: CGFloat = 24
    /// Roughly three caption lines from full ink down to the floor.
    static let liveRamp: CGFloat = 132

    /// `distance` from the focus line, or nil when nothing fades.
    static func opacity(distance: CGFloat?) -> Double {
        guard let distance, distance.isFinite else { return 1 }
        let progress = min(1, max(0, (distance - liveDeadzone) / liveRamp))
        return 1 - (1 - liveFloor) * Double(progress)
    }
}

extension EnvironmentValues {
    /// The live transcript's focus line in scroll coordinates while it
    /// follows the newest caption; nil while browsing or in playback.
    @Entry var liveCaptionFocusY: CGFloat?
}

extension View {
    /// Dims this part of a live caption row by its distance above the focus
    /// line. Rows choose what fades, so small margin type keeps full ink.
    func liveCaptionFade() -> some View { modifier(LiveCaptionFade()) }
}

private struct LiveCaptionFade: ViewModifier {
    @Environment(\.liveCaptionFocusY) private var focusY

    func body(content: Content) -> some View {
        let focusY = focusY
        return content.visualEffect { content, geometry in
            content.opacity(TranscriptFocusVisualPolicy.opacity(distance: focusY.map {
                abs(geometry.frame(in: .scrollView(axis: .vertical)).midY - $0)
            }))
        }
    }
}

enum TranscriptFollowOwnershipPolicy {
    static func followsActiveLine(
        mode: FocusedTranscriptMode,
        isFollowingLive: Bool
    ) -> Bool {
        mode == .playback || isFollowingLive
    }

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

/// A transcript that follows its active line, kept centered. Live
/// recording follows the newest caption until the user scrolls, then yields
/// ownership until they explicitly choose "Jump to live".
struct FocusedTranscriptView<Item: Identifiable, Row: View>: View where Item.ID: Hashable {
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFollowing = true

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
        self.segments = segments
        self.activeID = activeID
        self.height = height
        self.anchor = anchor
        self.followSignal = followSignal
        self.mode = mode
        self.scrollAccessibilityIdentifier = scrollAccessibilityIdentifier
        self.row = row
    }

    var body: some View {
        let focusY = anchor.y * height
        let liveFocusY: CGFloat? = mode == .live && isFollowing ? focusY : nil
        return ScrollViewReader { proxy in
            trackedScroll(
                identifiedScroll(
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 6) {
                            ForEach(segments) { segment in
                                row(segment, segment.id == activeID)
                                    .id(segment.id)
                            }
                        }
                        .environment(\.liveCaptionFocusY, liveFocusY)
                        // Pad so the first and last lines can reach the focus line.
                        .padding(.top, focusY)
                        .padding(.bottom, height - focusY)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .buttonStyle(.pvPrimary)
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

    private func trackedScroll<Content: View>(
        _ content: Content,
        onUserScroll: @escaping () -> Void
    ) -> some View {
        content.onScrollPhaseChange { _, phase in
            guard TranscriptFollowOwnershipPolicy.shouldYieldFollow(
                mode: mode,
                for: phase)
            else { return }
            onUserScroll()
        }
    }

    private func recenter(
        _ proxy: ScrollViewProxy,
        _ id: Item.ID?,
        animated: Bool = true
    ) {
        guard let id else { return }
        proxy.pvScrollTo(
            id, anchor: anchor, animation: animated ? .easeInOut(duration: 0.35) : nil,
            reduceMotion: reduceMotion)
    }
}
