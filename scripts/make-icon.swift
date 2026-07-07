// Generates assets/AppIcon.icns: a macOS-style rounded square with a
// gradient and a voice waveform. Run via `swift scripts/make-icon.swift`
// (requires full Xcode for AppKit). Idempotent; commit the result.
import AppKit
import Foundation

let size: CGFloat = 1024
let scale = size / 1024

func drawIcon(into context: CGContext) {
    // macOS icon grid: content square inset ~10%, radius ~22.5% of it.
    let inset: CGFloat = 100 * scale
    let square = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = CGPath(
        roundedRect: square, cornerWidth: 185 * scale, cornerHeight: 185 * scale, transform: nil)

    context.addPath(path)
    context.clip()

    // Diagonal gradient: deep slate → violet (voz que se enciende).
    let colors = [
        CGColor(red: 0.07, green: 0.09, blue: 0.18, alpha: 1),
        CGColor(red: 0.32, green: 0.15, blue: 0.75, alpha: 1),
    ]
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: square.minX, y: square.minY),
        end: CGPoint(x: square.maxX, y: square.maxY),
        options: [])

    // Waveform: 7 rounded bars, center-tallest, like a spoken word.
    let heights: [CGFloat] = [0.22, 0.40, 0.62, 0.86, 0.55, 0.34, 0.20]
    let barWidth: CGFloat = 56 * scale
    let gap: CGFloat = 44 * scale
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = (size - totalWidth) / 2
    let maxBarHeight = square.height * 0.62

    for (index, factor) in heights.enumerated() {
        let barHeight = maxBarHeight * factor
        let bar = CGRect(
            x: x, y: (size - barHeight) / 2, width: barWidth, height: barHeight)
        let barPath = CGPath(
            roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2,
            transform: nil)
        // The tallest bar pops in warm accent; the rest are soft white.
        let isPeak = index == 3
        context.setFillColor(
            isPeak
                ? CGColor(red: 0.99, green: 0.75, blue: 0.28, alpha: 1)
                : CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
        context.addPath(barPath)
        context.fillPath()
        x += barWidth + gap
    }
}

// Render master PNG.
let colorSpace = CGColorSpaceCreateDeviceRGB()
let context = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
drawIcon(into: context)
let master = context.makeImage()!

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = repoRoot.appendingPathComponent("assets")
let iconset = assets.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func write(_ image: CGImage, side: Int, name: String) throws {
    let url = iconset.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil)!
    // Resize by redrawing.
    let ctx = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
}

for side in [16, 32, 128, 256, 512] {
    try write(master, side: side, name: "icon_\(side)x\(side).png")
    try write(master, side: side * 2, name: "icon_\(side)x\(side)@2x.png")
}

// iconutil → .icns
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path,
]
try process.run()
process.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(process.terminationStatus == 0 ? "OK → assets/AppIcon.icns" : "iconutil failed")
