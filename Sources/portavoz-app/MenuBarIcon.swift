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

    /// The recording mark followed by the elapsed time in one image, so the
    /// status item shows a plain image instead of rasterizing a SwiftUI stack.
    @MainActor static func recording(elapsed: String) -> NSImage {
        let font = clockFont
        let text = elapsed as NSString
        // Digits share one width, so the placeholder measures every clock of its length.
        let template = RecordingClockTemplate.placeholder(for: elapsed) as NSString
        let textSize = template.size(withAttributes: [.font: font])
        let gap: CGFloat = 4
        let width = size.width + gap + ceil(textSize.width)
        return NSImage(size: NSSize(width: width, height: size.height), flipped: false) { rect in
            recording.draw(in: NSRect(origin: .zero, size: size))
            text.draw(
                at: NSPoint(x: size.width + gap, y: (rect.height - textSize.height) / 2),
                withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
            return true
        }
    }

    @MainActor private static let clockFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

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
