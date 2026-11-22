import SwiftUI

/// The three-strand mark in a single colour, sized to the label it leads.
struct PortavozMarkGlyph: View {
    let color: Color
    @ScaledMetric private var height: CGFloat

    init(color: Color, height: CGFloat = 14) {
        self.color = color
        _height = ScaledMetric(wrappedValue: height, relativeTo: .body)
    }

    var body: some View {
        let box = PortavozMark.glyphBox
        Canvas { context, size in
            let ink = color.resolve(in: context.environment).cgColor
            context.withCGContext { cg in
                // drawGlyph works in a y-up space; Canvas is y-down.
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
                PortavozMark.drawGlyph(in: cg, into: CGRect(origin: .zero, size: size)) { _ in ink }
            }
        }
        .frame(width: height * box.width / box.height, height: height)
        .accessibilityHidden(true)
    }
}
