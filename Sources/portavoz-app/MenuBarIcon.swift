import AppKit

/// The menu-bar «P» (design system: `portavoz-icon-p-menubar.svg`),
/// bundled as a pre-rendered PNG because its Fraunces glyph can't render
/// natively without shipping the font. Template, so it adapts to the
/// menu bar's appearance like any system icon.
enum MenuBarIcon {
    static let image: NSImage? = {
        // The 32 px render at 16 pt: crisp on Retina, where menu bars live.
        guard let url = Bundle.main.url(forResource: "pv-menubar-32", withExtension: "png"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }()
}
