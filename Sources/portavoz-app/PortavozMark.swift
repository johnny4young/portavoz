import CoreGraphics

/// The Portavoz mark: three voice strands, the middle one (amber, you)
/// swelling widest. Geometry lives on the 100-unit icon box, y down. The
/// menu-bar glyph and `scripts/make-icons.sh` both draw from here, so keep
/// this file free of AppKit.
enum PortavozMark {
    enum Strand: CaseIterable, Sendable {
        case top, middle, bottom

        fileprivate var geometry: Geometry {
            switch self {
            case .top: Geometry(y: 33, start: 24, end: 48, bulge: 8)
            case .middle: Geometry(y: 50, start: 36, end: 74, bulge: 13.5)
            case .bottom: Geometry(y: 67, start: 55, end: 77, bulge: 7)
            }
        }
    }

    /// The line's height and its lens: `start`/`end` on the line, `bulge`
    /// the control offset that sets its thickness.
    fileprivate struct Geometry {
        let y, start, end, bulge: CGFloat
    }

    /// The squircle on the icon box.
    static let iconBox = CGRect(x: 5, y: 5, width: 90, height: 90)
    static let iconCornerRadius: CGFloat = 22.5
    /// The strands alone, trimmed for the menu bar.
    static let glyphBox = CGRect(x: 12, y: 16, width: 76, height: 68)
    static let iconStrokeWidth: CGFloat = 3.4
    static let glyphStrokeWidth: CGFloat = 5.5

    static func line(_ strand: Strand) -> CGPath {
        let y = strand.geometry.y
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 20, y: y))
        path.addLine(to: CGPoint(x: 80, y: y))
        return path
    }

    static func swell(_ strand: Strand) -> CGPath {
        let shape = strand.geometry
        let (y, start, end) = (shape.y, shape.start, shape.end)
        let inset = (end - start) / 4
        let path = CGMutablePath()
        path.move(to: CGPoint(x: start, y: y))
        path.addCurve(
            to: CGPoint(x: end, y: y),
            control1: CGPoint(x: start + inset, y: y - shape.bulge),
            control2: CGPoint(x: end - inset, y: y - shape.bulge))
        path.addCurve(
            to: CGPoint(x: start, y: y),
            control1: CGPoint(x: end - inset, y: y + shape.bulge),
            control2: CGPoint(x: start + inset, y: y + shape.bulge))
        path.closeSubpath()
        return path
    }

    /// Maps icon units so `glyphBox` fills `rect` (aspect kept, centred) in a
    /// y-up space.
    static func glyphTransform(into rect: CGRect) -> CGAffineTransform {
        let box = glyphBox
        let scale = min(rect.width / box.width, rect.height / box.height)
        return CGAffineTransform(
            translationX: rect.midX - box.midX * scale, y: rect.midY + box.midY * scale
        ).scaledBy(x: scale, y: -scale)
    }

    /// Draws the menu-bar glyph into `rect` of a y-up context.
    static func drawGlyph(
        in context: CGContext, into rect: CGRect, color: (Strand) -> CGColor
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        context.concatenate(glyphTransform(into: rect))
        context.setLineCap(.round)
        context.setLineWidth(glyphStrokeWidth)
        for strand in Strand.allCases {
            let strandColor = color(strand)
            context.setStrokeColor(strandColor)
            context.addPath(line(strand))
            context.strokePath()
            context.setFillColor(strandColor)
            context.addPath(swell(strand))
            context.fillPath()
        }
    }
}
