import ApplicationKit
import PortavozCore
import SwiftUI

/// Radar's columns by due date: a solid chip is confirmed work, a dashed one a
/// suggestion that comes back for review that day.
struct CommitmentDueBoardView: View {
    let board: CommitmentDueBoard
    let open: (CommitmentDueBoard.Target) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CommitmentDueColumnsLayout {
                ForEach(board.lanes) { lane in
                    CommitmentDueLaneView(lane: lane, open: open)
                }
            }
            HStack(spacing: 16) {
                legend("confirmed", isOpen: false)
                legend("suggested, waiting for you", isOpen: true)
            }
            .font(.subheadline)
            .foregroundStyle(.ink3)
            .padding(.leading, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("commitment-due-board")
    }

    private func legend(_ title: LocalizedStringKey, isOpen: Bool) -> some View {
        HStack(spacing: 6) {
            VoiceDot(tint: .grey, size: 9, isOpen: isOpen)
            Text(title)
        }
    }
}

private struct CommitmentDueLaneView: View {
    static let visibleChips = 6

    let lane: CommitmentDueBoard.Lane
    let open: (CommitmentDueBoard.Target) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: title)
                    .font(.subheadline.weight(isUrgent ? .bold : .semibold))
                    .foregroundStyle(titleStyle)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(lane.count, format: .number)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.ink3)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(lane.chips.prefix(Self.visibleChips)) { chip in
                CommitmentDueChipView(chip: chip, open: open)
            }
            if lane.count > Self.visibleChips {
                Text(L10n.format("+%d more", lane.count - Self.visibleChips))
                    .font(.subheadline)
                    .foregroundStyle(.ink3)
                    .padding(.horizontal, 4)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 6, bottom: 10, trailing: 6))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            lane.column == .today ? PVDesign.nowBg : PVDesign.paperSunk,
            in: RoundedRectangle(cornerRadius: PVDesign.radiusTile))
        // Dark sunk paper sits a shade off the page; the ring keeps the column's edge.
        .overlay {
            if colorScheme == .dark {
                RoundedRectangle(cornerRadius: PVDesign.radiusTile).strokeBorder(PVDesign.line, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("commitment-due-column-\(key)")
    }

    private var isUrgent: Bool { lane.column == .overdue || lane.column == .today }

    /// Today takes the present's red; Overdue reads in full ink.
    private var titleStyle: Color {
        switch lane.column {
        case .today: PVDesign.now
        case .overdue: PVDesign.ink
        default: PVDesign.ink3
        }
    }

    private var title: String {
        switch lane.column {
        case .overdue: L10n.text("Overdue")
        case .today: L10n.text("Today")
        case .day(let date):
            date.formatted(Meeting.weekdayStyle.day())
        case .nextWeek: L10n.text("Next week")
        case .later: L10n.text("Later")
        }
    }

    private var key: String {
        switch lane.column {
        case .overdue: "overdue"
        case .today: "today"
        case .day(let date): "day-" + date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        case .nextWeek: "next-week"
        case .later: "later"
        }
    }
}

private struct CommitmentDueChipView: View {
    static let shape = RoundedRectangle(cornerRadius: PVDesign.radiusSmall)

    let chip: CommitmentDueBoard.Chip
    let open: (CommitmentDueBoard.Target) -> Void

    var body: some View {
        Button {
            open(chip.target)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VoiceDot(tint: chip.tint, size: 9, isOpen: !chip.isConfirmed)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(label)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline)
            .foregroundStyle(PVDesign.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 7)
            .background {
                if chip.isConfirmed {
                    Self.shape.fill(PVDesign.raise)
                    Self.shape.strokeBorder(PVDesign.line, lineWidth: 1)
                } else {
                    Self.shape.strokeBorder(PVDesign.line2, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .help(chip.isConfirmed ? L10n.text("Open the commitment") : L10n.text("Review in meeting"))
        .accessibilityLabel(Text(verbatim: plainLabel))
        .accessibilityValue(chip.isConfirmed ? L10n.text("Confirmed") : L10n.text("Suggested"))
        .accessibilityIdentifier("commitment-due-chip-\(chip.id.uuidString)")
    }

    private var plainLabel: String {
        [chip.owner, chip.task].compactMap(\.self).joined(separator: " · ")
    }

    private var label: AttributedString {
        var text = AttributedString(plainLabel)
        if let owner = chip.owner, let range = text.range(of: owner) {
            text[range].font = .subheadline.weight(.semibold)
        }
        return text
    }
}

/// Equal-width columns in balanced rows; each row is as tall as its tallest column.
struct CommitmentDueColumnsLayout: Layout {
    var spacing: CGFloat = 6
    var minimumColumnWidth: CGFloat = 116

    struct Grid: Equatable {
        let perRow: Int
        let columnWidth: CGFloat
    }

    func grid(count: Int, width: CGFloat) -> Grid {
        guard count > 0 else { return Grid(perRow: 1, columnWidth: width) }
        let fit = max(1, Int((width + spacing) / (minimumColumnWidth + spacing)))
        let rows = (count + min(fit, count) - 1) / min(fit, count)
        let perRow = (count + rows - 1) / rows
        return Grid(perRow: perRow, columnWidth: max(0, (width - CGFloat(perRow - 1) * spacing) / CGFloat(perRow)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = resolvedWidth(proposal, count: subviews.count)
        let heights = rowHeights(subviews, grid: grid(count: subviews.count, width: width))
        return CGSize(width: width, height: heights.reduce(0, +) + CGFloat(heights.count - 1) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = grid(count: subviews.count, width: bounds.width)
        var y = bounds.minY
        for (row, height) in rowHeights(subviews, grid: grid).enumerated() {
            for column in 0..<grid.perRow {
                let index = row * grid.perRow + column
                guard index < subviews.count else { break }
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + CGFloat(column) * (grid.columnWidth + spacing), y: y),
                    proposal: ProposedViewSize(width: grid.columnWidth, height: height))
            }
            y += height + spacing
        }
    }

    private func resolvedWidth(_ proposal: ProposedViewSize, count: Int) -> CGFloat {
        if let width = proposal.width, width.isFinite { return width }
        return CGFloat(count) * (minimumColumnWidth + spacing) - spacing
    }

    private func rowHeights(_ subviews: Subviews, grid: Grid) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: grid.perRow).map { start in
            subviews[start..<min(start + grid.perRow, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: grid.columnWidth, height: nil)).height }
                .max() ?? 0
        }
    }
}
