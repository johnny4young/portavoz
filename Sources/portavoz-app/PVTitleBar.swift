import CoreGraphics

/// Room the window takes from a detail pane's title-bar row.
enum PVTitleBar {
    /// The window toolbar's own margins and the background-work indicator.
    static let chrome: CGFloat = 60
    /// Traffic lights and the sidebar toggle, when the sidebar is hidden.
    static let windowControls: CGFloat = 140

    static func reserved(sidebarVisible: Bool) -> CGFloat {
        chrome + (sidebarVisible ? 0 : windowControls)
    }

    /// A detail pane's width, and whether the sidebar is showing.
    struct Frame: Equatable {
        var width: CGFloat = 0
        var sidebarVisible = true

        init() {}

        /// A detail pane at the window's leading edge means the sidebar is hidden.
        init(_ global: CGRect) {
            width = global.width.rounded()
            sidebarVisible = global.minX > 1
        }
    }
}
