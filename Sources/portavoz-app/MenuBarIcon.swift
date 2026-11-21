import AppKit

/// The menu-bar mark, drawn from `PortavozMark` so it stays sharp at any
/// scale. Idle is a template the menu bar tints; recording keeps the strands
/// in the label colour and paints the middle swell in the live red.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 16)

    static let idle: NSImage = {
        let image = render { _ in .black }
        image.isTemplate = true
        return image
    }()

    /// Not a template: the handler re-runs per appearance, so `labelColor`
    /// and the red follow a light or dark menu bar.
    static let recording: NSImage = render { strand in
        strand == .middle ? PVDesign.Tone.now.nsColor : .labelColor
    }

    private static func render(
        _ color: @escaping @Sendable (PortavozMark.Strand) -> NSColor
    ) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            PortavozMark.drawGlyph(in: context, into: rect) { color($0).cgColor }
            return true
        }
    }
}
