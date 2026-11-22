import SwiftUI

/// Today's title-bar row: the day on the leading edge, then Ask and the
/// automations pill on the trailing edge.
struct HomeToolbar: ToolbarContent {
    let layout: HomeToolbarLayout
    let suggestions: [String]
    let onAsk: (String?) -> Void
    let onOpenAutomations: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(alignment: .firstTextBaseline, spacing: HomeToolbarLayout.spacing) {
                Text(layout.title)
                    .font(.body.weight(.bold))
                    .foregroundStyle(PVDesign.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("home-title")
                Text(layout.date)
                    .foregroundStyle(PVDesign.ink3)
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, HomeToolbarLayout.titleInset)
        }
        .sharedBackgroundVisibility(.hidden)
        // A Mac toolbar puts primary actions on the leading edge; the spacer sends these trailing.
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .automatic) {
            HStack(spacing: HomeToolbarLayout.spacing) {
                if let width = layout.askWidth {
                    HomeAskField(suggestions: suggestions, onAsk: onAsk)
                        .frame(width: width)
                } else {
                    HomeAskButton(suggestions: suggestions, onAsk: onAsk)
                }
                if let automations = layout.automations {
                    Button(action: onOpenAutomations) {
                        Label(automations, systemImage: PVSymbol.automations)
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(PVDesign.green)
                            .padding(.horizontal, HomeToolbarLayout.pillPadding)
                            .frame(height: 26)
                            .background(PVDesign.greenBg, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Review the automations Portavoz suggested from your meetings")
                    .accessibilityIdentifier("home-automations")
                }
            }
            .padding(.trailing, HomeToolbarLayout.trailingInset)
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

/// How wide Ask can be beside the day and the pill. A width too narrow for
/// the field's minimum folds Ask into its glyph instead of truncating it.
struct HomeToolbarLayout: Equatable {
    static let askWidths: ClosedRange<CGFloat> = 240...330
    static let spacing: CGFloat = 14
    static let pillPadding: CGFloat = 11
    /// The pill's glyph and its gap to the label.
    static let pillGlyph: CGFloat = 20
    static let titleInset: CGFloat = 16
    static let trailingInset: CGFloat = 12
    /// The window toolbar's own margins and the background-work indicator.
    static let chrome: CGFloat = 60
    /// Traffic lights and the sidebar toggle, when the sidebar is hidden.
    static let windowControls: CGFloat = 140

    let title: String
    let date: String
    let automations: String?
    let askWidth: CGFloat?

    init(width: CGFloat, sidebarVisible: Bool, title: String, date: String, automations: String?) {
        self.title = title
        self.date = date
        self.automations = automations
        askWidth = Self.askWidth(
            available: width
                - Self.reserved(title: title, date: date, automations: automations, sidebarVisible: sidebarVisible))
    }

    /// Everything in the row except Ask.
    static func reserved(title: String, date: String, automations: String?, sidebarVisible: Bool) -> CGFloat {
        titleWidth(title: title, date: date)
            + (automations.map { pillWidth($0) + spacing } ?? 0)
            + chrome + titleInset + trailingInset
            + (sidebarVisible ? 0 : windowControls)
    }

    /// The field's width, or nil when even its minimum does not fit.
    static func askWidth(available: CGFloat) -> CGFloat? {
        available < askWidths.lowerBound ? nil : min(available, askWidths.upperBound)
    }

    static func titleWidth(title: String, date: String) -> CGFloat {
        PVTextMetrics.width(title, PVTextMetrics.font(.body, .bold)) + spacing
            + PVTextMetrics.width(date, PVTextMetrics.font(.body))
    }

    static func pillWidth(_ label: String) -> CGFloat {
        PVTextMetrics.width(label, PVTextMetrics.font(.subheadline, .semibold)) + pillGlyph + 2 * pillPadding
    }
}

/// Ask folded into its glyph: the whole field opens in a popover.
private struct HomeAskButton: View {
    let suggestions: [String]
    let onAsk: (String?) -> Void

    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Image(systemName: PVSymbol.ask)
                .foregroundStyle(PVDesign.ink3)
                .frame(width: 30, height: 30)
                .background(PVDesign.raise, in: Circle())
                .overlay(Circle().strokeBorder(PVDesign.line2, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Ask your meetings…")
        .accessibilityLabel(L10n.text("Ask"))
        .accessibilityIdentifier("home-ask-open")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            HomeAskField(suggestions: suggestions) { question in
                isPresented = false
                onAsk(question)
            }
            .frame(width: HomeToolbarLayout.askWidths.upperBound)
            .padding(PVDesign.space3)
        }
    }
}
