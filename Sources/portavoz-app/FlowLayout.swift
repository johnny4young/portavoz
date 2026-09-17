import SwiftUI

/// A leading-aligned wrapping row: subviews flow onto new lines instead of
/// compressing. The cast row needs it — a single HStack squeezes the last
/// chip into a one-character-wide sliver once pills, suggestions, and offer
/// chips add up.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let rows = rows(fitting: proposal.width ?? .infinity, subviews: subviews)
        var height: CGFloat = 0
        var width: CGFloat = 0
        for row in rows {
            var rowHeight: CGFloat = 0
            var rowWidth: CGFloat = 0
            for subview in row {
                let size = itemSize(subview, fitting: proposal.width ?? .infinity)
                rowHeight = max(rowHeight, size.height)
                rowWidth += size.width
            }
            rowWidth += spacing * CGFloat(max(0, row.count - 1))
            height += rowHeight
            width = max(width, rowWidth)
        }
        height += rowSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for row in rows(fitting: bounds.width, subviews: subviews) {
            var x = bounds.minX
            let sizes = row.map { itemSize($0, fitting: bounds.width) }
            let rowHeight = sizes.map(\.height).max() ?? 0
            for (subview, size) in zip(row, sizes) {
                subview.place(
                    at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + rowSpacing
        }
    }

    /// A child never gets more than the row width: a long citation title is
    /// proposed the row's width so its own line limit truncates it, instead
    /// of being placed at its natural width past the viewport.
    private func itemSize(_ subview: Subviews.Element, fitting width: CGFloat) -> CGSize {
        let natural = subview.sizeThatFits(.unspecified)
        guard width.isFinite, natural.width > width else { return natural }
        let constrained = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: min(constrained.width, width), height: constrained.height)
    }

    private func rows(fitting width: CGFloat, subviews: Subviews) -> [[Subviews.Element]] {
        var rows: [[Subviews.Element]] = [[]]
        var x: CGFloat = 0
        for subview in subviews {
            let size = itemSize(subview, fitting: width)
            if x > 0, x + size.width > width {
                rows.append([subview])
                x = size.width + spacing
            } else {
                rows[rows.count - 1].append(subview)
                x += size.width + spacing
            }
        }
        return rows.filter { !$0.isEmpty }
    }
}
