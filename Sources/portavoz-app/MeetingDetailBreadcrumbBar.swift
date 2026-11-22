import SwiftUI

extension View {
    /// The meeting's title bar: the breadcrumb leads, the actions trail. The
    /// window keeps the title for the Window menu; the breadcrumb draws it.
    func meetingTitleBar<Actions: View>(
        title: String, current: Route, navigation: DetailNavigation,
        open: @escaping @MainActor (Route) -> Void,
        step: @escaping @MainActor (DetailNavigationHistory.Direction) -> Void,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        modifier(MeetingDetailTitleBar(
            bar: MeetingDetailBreadcrumbBar(
                title: title, current: current, navigation: navigation, open: open, step: step),
            actions: actions))
    }
}

/// Owns the detail's measured frame so a resize re-renders the title bar, not the page.
private struct MeetingDetailTitleBar<Actions: View>: ViewModifier {
    let bar: MeetingDetailBreadcrumbBar
    let actions: () -> Actions

    @State private var frame = PVTitleBar.Frame()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: PVTitleBar.Frame.self) { PVTitleBar.Frame($0.frame(in: .global)) } action: {
                frame = $0
            }
            .navigationTitle(bar.title)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    bar.frame(frame)
                }
                .sharedBackgroundVisibility(.hidden)
                // A Mac toolbar puts primary actions on the leading edge; the spacer sends these trailing.
                ToolbarSpacer(.flexible)
                ToolbarItem(placement: .automatic) { actions() }
                    .sharedBackgroundVisibility(.hidden)
            }
    }
}

/// Back and forward, then "Today › title".
struct MeetingDetailBreadcrumbBar: View {
    let title: String
    let current: Route
    let navigation: DetailNavigation
    let open: @MainActor (Route) -> Void
    let step: @MainActor (DetailNavigationHistory.Direction) -> Void
    private var measured = PVTitleBar.Frame()

    init(
        title: String, current: Route, navigation: DetailNavigation,
        open: @escaping @MainActor (Route) -> Void,
        step: @escaping @MainActor (DetailNavigationHistory.Direction) -> Void
    ) {
        self.title = title
        self.current = current
        self.navigation = navigation
        self.open = open
        self.step = step
    }

    func frame(_ frame: PVTitleBar.Frame) -> Self {
        var bar = self
        bar.measured = frame
        return bar
    }

    var body: some View {
        let origin = navigation.history.origin
        let layout = MeetingDetailBreadcrumbLayout(frame: measured, origin: origin.title, title: title)
        HStack(spacing: 2) {
            chevron(.back, symbol: "chevron.left", label: "Back", id: "detail-back", key: "[")
            chevron(.forward, symbol: "chevron.right", label: "Forward", id: "detail-forward", key: "]")
            HStack(spacing: MeetingDetailBreadcrumbLayout.separatorSpacing) {
                Button(origin.title) { open(origin.route) }
                    .buttonStyle(.plain)
                    .foregroundStyle(PVDesign.ink3)
                    .accessibilityIdentifier("detail-breadcrumb-origin")
                Text(verbatim: MeetingDetailBreadcrumbLayout.separator)
                    .foregroundStyle(PVDesign.ink3)
                    .accessibilityHidden(true)
                Text(title)
                    .fontWeight(.semibold)
                    .foregroundStyle(PVDesign.ink)
                    .truncationMode(.tail)
                    .frame(width: layout.titleWidth, alignment: .leading)
                    .help(title)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("detail-breadcrumb-title")
            }
            .lineLimit(1)
            .padding(.leading, MeetingDetailBreadcrumbLayout.leadingGap)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("detail-breadcrumb")
        }
        .fixedSize()
    }

    private func chevron(
        _ direction: DetailNavigationHistory.Direction, symbol: String, label: String, id: String,
        key: KeyEquivalent
    ) -> some View {
        let enabled = navigation.canStep(direction, from: current)
        return Button { step(direction) } label: {
            MeetingToolbarGlyph(systemName: symbol)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .keyboardShortcut(key, modifiers: .command)
        .help(L10n.text(label))
        .accessibilityLabel(L10n.text(label))
        .accessibilityIdentifier(id)
    }
}

/// How wide the title can be beside the meeting's actions. Toolbar items take
/// their ideal width and overflow, so a long title gets a measured width.
struct MeetingDetailBreadcrumbLayout: Equatable {
    static let separator = "›"
    static let leadingGap: CGFloat = 8
    static let separatorSpacing: CGFloat = 6
    static let minimumTitle: CGFloat = 80
    /// Automations pill, re-transcribe, share and More.
    static let actions: CGFloat = 320
    private static let separatorWidth = PVTextMetrics.width(separator, PVTextMetrics.font(.body))

    let titleWidth: CGFloat

    init(frame: PVTitleBar.Frame, origin: String, title: String) {
        let ideal = PVTextMetrics.width(title, PVTextMetrics.font(.body, .semibold))
        let reserved = 2 * MeetingToolbarGlyph.side + Self.leadingGap
            + PVTextMetrics.width(origin, PVTextMetrics.font(.body)) + Self.separatorWidth
            + 2 * Self.separatorSpacing + Self.actions + PVTitleBar.reserved(sidebarVisible: frame.sidebarVisible)
        titleWidth = min(ideal, max(Self.minimumTitle, frame.width - reserved))
    }
}
