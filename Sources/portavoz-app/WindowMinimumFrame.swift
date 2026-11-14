import SwiftUI

/// Gives a window its declared minimum size without measuring its content.
/// AppKit asks a `WindowGroup`'s root for its minimum on every layout pass, and
/// a `.frame(minWidth:minHeight:)` answers by measuring the whole tree first.
struct WindowMinimumFrame: Layout {
    let minimum: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        if let width = proposal.width, let height = proposal.height,
            width <= minimum.width, height <= minimum.height {
            return minimum
        }
        return subviews.first?.sizeThatFits(proposal) ?? minimum
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

extension View {
    /// The window's minimum size, answered without measuring this content.
    func windowMinimumSize(width: CGFloat, height: CGFloat) -> some View {
        WindowMinimumFrame(minimum: CGSize(width: width, height: height)) {
            frame(minWidth: width, minHeight: height)
        }
    }
}
