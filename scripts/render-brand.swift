// Brand renderer for scripts/make-icons.sh, compiled with PortavozMark.swift
// so the icon, the SVGs and the social card all draw one geometry.
import AppKit
import CoreText
import Foundation

@main
enum RenderBrand {
    struct Palette {
        let top: String, middle: String, bottom: String
        let gradient: (String, String)
        let rim: (String, Double)

        func color(_ strand: PortavozMark.Strand) -> String {
            switch strand {
            case .top: top
            case .middle: middle
            case .bottom: bottom
            }
        }
    }

    // Voice tones from PVDesign: cobalt, you (amber) and madder.
    static let light = Palette(
        top: "#3B6BD6", middle: "#F2B33D", bottom: "#C9437B",
        gradient: ("#FFFDFA", "#F0E4D7"), rim: ("#FFFFFF", 0.9))
    static let dark = Palette(
        top: "#7DA1F6", middle: "#F2B33D", bottom: "#EE7DAD",
        gradient: ("#22302D", "#0F1716"), rim: ("#FFFFFF", 0.16))

    static func main() throws {
        let args = CommandLine.arguments.dropFirst()
        switch args.first {
        case "vectors": try writeVectors()
        case "social" where args.count == 2: try writeSocial(iconPath: args.last!)
        default:
            FileHandle.standardError.write(Data("usage: render-brand vectors | social <icon.png>\n".utf8))
            exit(64)
        }
    }

    // MARK: Vectors

    static func n(_ v: CGFloat) -> String {
        String(format: "%.2f", v).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    static func svgPath(_ path: CGPath) -> String {
        var d = ""
        path.applyWithBlock { element in
            let p = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: d += "M\(n(p[0].x)) \(n(p[0].y))"
            case .addLineToPoint: d += "L\(n(p[0].x)) \(n(p[0].y))"
            case .addCurveToPoint:
                d += "C\(n(p[0].x)) \(n(p[0].y)) \(n(p[1].x)) \(n(p[1].y)) \(n(p[2].x)) \(n(p[2].y))"
            case .addQuadCurveToPoint: d += "Q\(n(p[0].x)) \(n(p[0].y)) \(n(p[1].x)) \(n(p[1].y))"
            case .closeSubpath: d += "Z"
            @unknown default: break
            }
        }
        return d
    }

    static func strands(_ color: (PortavozMark.Strand) -> String, width: CGFloat) -> String {
        PortavozMark.Strand.allCases.map { strand in
            let c = color(strand)
            return """
                <path d="\(svgPath(PortavozMark.line(strand)))" fill="none" stroke="\(c)" \
                stroke-width="\(width)" stroke-linecap="round"/>\
                <path d="\(svgPath(PortavozMark.swell(strand)))" fill="\(c)"/>
                """
        }.joined()
    }

    static func box(_ rect: CGRect) -> String {
        "\(Int(rect.minX)) \(Int(rect.minY)) \(Int(rect.width)) \(Int(rect.height))"
    }

    static func rect(_ r: CGRect, radius: CGFloat) -> String {
        "x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\" rx=\"\(n(radius))\""
    }

    static func iconSVG(_ palette: Palette, id: String) -> String {
        let box = PortavozMark.iconBox, radius = PortavozMark.iconCornerRadius
        return """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">\
            <defs><linearGradient id="\(id)" x1="0" y1="0" x2="0" y2="1">\
            <stop offset="0" stop-color="\(palette.gradient.0)"/>\
            <stop offset="1" stop-color="\(palette.gradient.1)"/></linearGradient></defs>\
            <rect \(rect(box, radius: radius)) fill="url(#\(id))"/>\
            <rect \(rect(box.insetBy(dx: 0.5, dy: 0.5), radius: radius - 0.5)) fill="none" \
            stroke="\(palette.rim.0)" stroke-opacity="\(palette.rim.1)"/>\
            \(strands(palette.color, width: PortavozMark.iconStrokeWidth))</svg>

            """
    }

    /// One Icon Composer layer: the strands on the squircle's own box, so
    /// the system grid, mask and shadow apply as for any Tahoe icon.
    static func layerSVG(_ palette: Palette) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" \
        viewBox="\(box(PortavozMark.iconBox))">\
        \(strands(palette.color, width: PortavozMark.iconStrokeWidth))</svg>

        """
    }

    static func gradientFill(_ palette: Palette) -> [String: Any] {
        func srgb(_ hex: String) -> String {
            let c = rgb(hex).map { String(format: "%.5f", $0) }
            return "srgb:\(c.joined(separator: ",")),1.00000"
        }
        return [
            "linear-gradient": [srgb(palette.gradient.0), srgb(palette.gradient.1)],
            "orientation": ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 1]],
        ]
    }

    static func writeVectors() throws {
        let fm = FileManager.default
        func write(_ text: String, _ path: String) throws {
            try fm.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            print("→ \(path)")
        }

        try write(layerSVG(light), "assets/AppIcon.icon/Assets/strands-light.svg")
        try write(layerSVG(dark), "assets/AppIcon.icon/Assets/strands-dark.svg")
        let document: [String: Any] = [
            "fill-specializations": [
                ["value": gradientFill(light)],
                ["appearance": "dark", "value": gradientFill(dark)],
            ],
            "groups": [[
                "layers": [[
                    "name": "Strands",
                    "glass": false,
                    "image-name-specializations": [
                        ["value": "strands-light.svg"],
                        ["appearance": "dark", "value": "strands-dark.svg"],
                    ],
                ]],
                "shadow": ["kind": "none", "opacity": 0],
                "specular": false,
                "translucency": ["enabled": false, "value": 0],
            ]],
            "supported-platforms": ["squares": ["macOS"]],
        ]
        let json = try JSONSerialization.data(
            withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try write(String(decoding: json, as: UTF8.self) + "\n", "assets/AppIcon.icon/icon.json")

        let darkIcon = iconSVG(dark, id: "pv-icon-dark")
        try write(darkIcon, "site/assets/portavoz-icon.svg")
        try write(darkIcon, "docs/design/ds/assets/portavoz-icon.svg")
        try write(iconSVG(light, id: "pv-icon-light"), "docs/design/ds/assets/portavoz-icon-light.svg")
        try write(
            """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="\(box(PortavozMark.glyphBox))">\
            \(strands({ _ in "currentColor" }, width: PortavozMark.glyphStrokeWidth))</svg>

            """, "docs/design/ds/assets/portavoz-mark-menubar.svg")
    }

    // MARK: Social card

    static func rgb(_ hex: String) -> [CGFloat] {
        let v = Int(hex.dropFirst(), radix: 16)!
        return [v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF].map { CGFloat($0) / 255 }
    }

    static func nsColor(_ hex: String, alpha: CGFloat = 1) -> NSColor {
        let c = rgb(hex)
        return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: alpha)
    }

    static func fraunces(size: CGFloat, weight: CGFloat, italic: Bool) -> NSFont {
        func tag(_ s: String) -> Int { s.utf8.reduce(0) { $0 << 8 | Int($1) } }
        let file = italic ? "Fraunces-Italic[SOFT,WONK,opsz,wght].ttf" : "Fraunces[SOFT,WONK,opsz,wght].ttf"
        let url = URL(fileURLWithPath: "Resources/Fonts/Fraunces/\(file)")
        guard let base = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first
        else { fatalError("missing \(url.path)") }
        let variation: [Int: CGFloat] = [
            tag("wght"): weight, tag("SOFT"): 100, tag("opsz"): min(size, 144), tag("WONK"): 0,
        ]
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            base, [kCTFontVariationAttribute: variation] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }

    static func writeSocial(iconPath: String) throws {
        guard let icon = NSImage(contentsOfFile: iconPath) else { fatalError("cannot read \(iconPath)") }
        let size = NSSize(width: 1280, height: 640)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.current = nil }

        NSGradient(starting: nsColor("#FBF7F2"), ending: nsColor("#F6F0E8"))!
            .draw(in: NSRect(origin: .zero, size: size), angle: -90)
        icon.draw(in: NSRect(x: 34, y: 84, width: 472, height: 472))

        let ink = nsColor("#14201E"), ink2 = nsColor("#46534F")
        func draw(_ text: String, _ font: NSFont, _ color: NSColor, x: CGFloat, y: CGFloat) {
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
                .draw(at: NSPoint(x: x, y: y))
        }
        let x: CGFloat = 520
        draw("Portavoz", fraunces(size: 136, weight: 360, italic: false), ink, x: x - 6, y: 340)
        draw("Knows who said what — locally.", fraunces(size: 40, weight: 400, italic: true), ink, x: x, y: 290)
        draw(
            "Live transcription · on-device voices · local summaries",
            .systemFont(ofSize: 22, weight: .regular), ink2, x: x, y: 246)

        let command = "brew install --cask johnny4young/tap/portavoz"
        let mono = NSFont.monospacedSystemFont(ofSize: 18, weight: .medium)
        let textSize = NSAttributedString(string: command, attributes: [.font: mono]).size()
        let pill = NSRect(x: x, y: 160, width: textSize.width + 40, height: textSize.height + 22)
        let shape = NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10)
        nsColor("#FFFDFA").setFill()
        shape.fill()
        nsColor("#1E1612", alpha: 0.2).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        draw(command, mono, ink, x: pill.minX + 20, y: pill.minY + 11)

        let out = "assets/social-preview.png"
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        print("→ \(out)")
    }
}
