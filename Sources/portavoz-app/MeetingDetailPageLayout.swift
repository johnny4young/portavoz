import SwiftUI

/// The meeting page below its header: generated material, the margin and the
/// transcript, in that subview order. A wide detail puts the margin beside the
/// material and transcript, top-aligned with the standfirst; a narrower one
/// reads as one column with the margin between the material and the
/// transcript, so it never takes width from the reading column.
struct MeetingDetailPageLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? MeetingDetailPageMetrics.fallbackWidth
        let frames = Self.frames(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = Self.frames(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private static func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        MeetingDetailPageMetrics.frames(width: width, count: subviews.count) { index, width in
            subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
    }
}

enum MeetingDetailPageMetrics {
    static let gap: CGFloat = 28
    static let sectionSpacing: CGFloat = 16
    static let minimumMainWidth: CGFloat = 540
    static let marginRange: ClosedRange<CGFloat> = 260...300
    /// Past this the lines grow too long to read; the page centres instead.
    static let maximumPageWidth: CGFloat = 1240
    static let sideGutter: CGFloat = 28
    static let fallbackWidth: CGFloat = 640
    static let inlineGutterBelow: CGFloat = 640

    /// Whether a column this wide puts the summary's counts and the
    /// transcript's speaker margin above their text.
    static func usesInlineGutter(width: CGFloat) -> Bool {
        width > 0 && width < inlineGutterBelow
    }

    /// The margin's width beside the reading column, or nil for one column.
    static func marginWidth(forPageWidth width: CGFloat) -> CGFloat? {
        let margin = min(marginRange.upperBound, max(marginRange.lowerBound, (width - gap) * 0.3))
        return width - margin - gap >= minimumMainWidth ? margin : nil
    }

    /// Frames for material, margin and transcript; `height` measures one of
    /// them at a width. An empty section adds no spacing.
    static func frames(
        width: CGFloat,
        count: Int,
        height: (Int, CGFloat) -> CGFloat
    ) -> [CGRect] {
        guard count == 3, let margin = marginWidth(forPageWidth: width) else {
            return stacked((0..<count).map { ($0, width) }, height: height)
        }
        let main = width - margin - gap
        var frames = stacked([(0, main), (2, main)], height: height)
        frames.insert(CGRect(x: main + gap, y: 0, width: margin, height: height(1, margin)), at: 1)
        return frames
    }

    private static func stacked(
        _ sections: [(index: Int, width: CGFloat)],
        height: (Int, CGFloat) -> CGFloat
    ) -> [CGRect] {
        var y: CGFloat = 0
        return sections.map { section in
            let sectionHeight = height(section.index, section.width)
            if sectionHeight > 0, y > 0 { y += sectionSpacing }
            defer { y += sectionHeight }
            return CGRect(x: 0, y: y, width: section.width, height: sectionHeight)
        }
    }
}
