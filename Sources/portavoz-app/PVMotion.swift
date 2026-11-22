import SwiftUI

/// The only path to animation in the app, so Reduce Motion cannot be skipped.
enum PVMotion {
    /// `animation`, or nil under Reduce Motion.
    static func resolved(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// Applies `body` animated, or in a non-animated transaction under Reduce
    /// Motion or a nil `animation`; `completion` then runs at once.
    @MainActor
    static func perform(
        _ animation: Animation? = .default,
        reduceMotion: Bool,
        _ body: () -> Void,
        completion: (() -> Void)? = nil
    ) {
        guard let animation = resolved(animation, reduceMotion: reduceMotion) else {
            withAnimation(nil, body)
            completion?()
            return
        }
        guard let completion else { return withAnimation(animation, body) }
        withAnimation(animation, completionCriteria: .logicallyComplete, body, completion: completion)
    }
}

extension ScrollViewProxy {
    /// `scrollTo` that glides with `animation` and jumps under Reduce Motion or a nil one.
    @MainActor
    func pvScrollTo<ID: Hashable>(
        _ id: ID,
        anchor: UnitPoint? = nil,
        animation: Animation? = .default,
        reduceMotion: Bool
    ) {
        PVMotion.perform(animation, reduceMotion: reduceMotion) { scrollTo(id, anchor: anchor) }
    }
}

extension View {
    /// `.animation(_:value:)` that reads Reduce Motion itself.
    func pvAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(PVAnimationModifier(animation: animation, value: value))
    }
}

private struct PVAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation?
    let value: Value

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(PVMotion.resolved(animation, reduceMotion: reduceMotion), value: value)
    }
}

/// A per-frame timeline that hands its content the current time, or nil and no
/// timeline at all under Reduce Motion or while `paused`.
struct PVAnimationTimeline<Content: View>: View {
    var paused = false
    @ViewBuilder let content: (TimeInterval?) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion || paused {
            content(nil)
        } else {
            TimelineView(.animation) { timeline in
                content(timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }
}
