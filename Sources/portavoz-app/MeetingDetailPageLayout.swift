import SwiftUI

/// The page scroll's slot above the player. It takes the size it is offered
/// without asking the scroll, so a minimum or ideal size query from the window
/// never lays the lazy transcript out at a width the page does not have.
struct MeetingDetailViewportLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let fallback = MeetingDetailPageMetrics.fallbackWidth
        return proposal.replacingUnspecifiedDimensions(by: CGSize(width: fallback, height: fallback))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }

    func explicitAlignment(
        of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? { nil }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? { nil }
}

/// The meeting page below its header: generated material, the margin and the
/// transcript, in that subview order. A wide detail puts the margin beside the
/// material, top-aligned with the standfirst, and gives the transcript the full
/// width so its notes can sit in the margin beside their lines; a narrower one
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

    // The default merges the subviews' guides by placing them again, which
    // lays the lazy transcript out a second time on every measurement.
    func explicitAlignment(
        of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? { nil }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? { nil }

    private static func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let holdsNotes = subviews.last?[MeetingTranscriptHoldsMarginNotes.self] ?? false
        return MeetingDetailPageMetrics.frames(
            width: width, count: subviews.count, transcriptHoldsMarginNotes: holdsNotes
        ) { index, width in
            subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
    }
}

/// A transcript item across the page: the line in the reading column and, when
/// given, its notes in the margin beside it or folded under it. Widths come
/// from the proposal alone, so no measured width ever reaches view state.
struct MeetingTranscriptLineLayout: Layout {
    /// How far the line's active outline overhangs the page on each side.
    var overhang: CGFloat = 0
    /// Where folded notes sit inside the row, under the line's text.
    var foldedInsets = EdgeInsets()

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? MeetingDetailPageMetrics.fallbackWidth
        return CGSize(width: width, height: arrangement(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrangement(width: bounds.width, subviews: subviews).frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    // No guides to merge; the default would place the line and notes to measure a row.
    func explicitAlignment(
        of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? { nil }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? { nil }

    private func arrangement(width: CGFloat, subviews: Subviews) -> MeetingDetailPageMetrics.LineArrangement {
        MeetingDetailPageMetrics.lineArrangement(
            width: width, overhang: overhang, hasNotes: subviews.count > 1, foldedInsets: foldedInsets
        ) { index, width in
            subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
    }
}

/// Set on the transcript when a line carries margin notes, which need the
/// margin clear beside them.
struct MeetingTranscriptHoldsMarginNotes: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// The page column: side gutters, capped and centred past the readable width.
    func meetingPageColumn() -> some View {
        padding(.horizontal, MeetingDetailPageMetrics.sideGutter)
            .frame(maxWidth: MeetingDetailPageMetrics.maximumPageWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity)
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

    /// The reading column inside a page this wide: what is left beside the margin.
    static func readingWidth(forPageWidth width: CGFloat) -> CGFloat {
        marginWidth(forPageWidth: width).map { width - $0 - gap } ?? width
    }

    struct LineArrangement: Equatable {
        var frames: [CGRect]
        var height: CGFloat
    }

    /// A transcript line and its notes in a row `width` wide, whose line
    /// overhangs the page by `overhang` on each side; `height` measures one of
    /// them at a width.
    static func lineArrangement(
        width: CGFloat,
        overhang: CGFloat,
        hasNotes: Bool,
        foldedInsets: EdgeInsets,
        height: (Int, CGFloat) -> CGFloat
    ) -> LineArrangement {
        let page = max(0, width - 2 * overhang)
        let lineWidth = readingWidth(forPageWidth: page) + 2 * overhang
        let line = CGRect(x: 0, y: 0, width: lineWidth, height: height(0, lineWidth))
        guard hasNotes else { return LineArrangement(frames: [line], height: line.height) }
        if let margin = marginWidth(forPageWidth: page) {
            let notes = CGRect(x: lineWidth + gap - overhang, y: 0, width: margin, height: height(1, margin))
            return LineArrangement(frames: [line, notes], height: max(line.maxY, notes.maxY))
        }
        let notesWidth = max(0, width - foldedInsets.leading - foldedInsets.trailing)
        let notes = CGRect(
            x: foldedInsets.leading, y: line.maxY + foldedInsets.top,
            width: notesWidth, height: height(1, notesWidth))
        return LineArrangement(frames: [line, notes], height: notes.maxY + foldedInsets.bottom)
    }

    /// Frames for material, margin and transcript; `height` measures one of
    /// them at a width. An empty section adds no spacing. The transcript spans
    /// the page so its margin notes line up under the margin; with notes it
    /// also starts below a margin taller than the material, so no card meets it.
    static func frames(
        width: CGFloat,
        count: Int,
        transcriptHoldsMarginNotes: Bool = false,
        height: (Int, CGFloat) -> CGFloat
    ) -> [CGRect] {
        guard count == 3, let margin = marginWidth(forPageWidth: width) else {
            return stacked((0..<count).map { ($0, width) }, height: height)
        }
        let main = width - margin - gap
        let marginHeight = height(1, margin)
        var frames = stacked([(0, main), (2, width)], height: height)
        if transcriptHoldsMarginNotes, marginHeight > 0, frames[1].height > 0 {
            frames[1].origin.y = max(frames[1].minY, marginHeight + sectionSpacing)
        }
        frames.insert(CGRect(x: main + gap, y: 0, width: margin, height: marginHeight), at: 1)
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
