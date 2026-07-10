// Generates assets/social-preview.png (1280×640): the GitHub social card,
// in the app icon's visual language — slate→violet gradient, the spoken-word
// waveform with the warm peak, wordmark and tagline. Run via
// `swift scripts/make-social-preview.swift` (requires full Xcode for AppKit).
// Idempotent; commit the result and upload it in Settings → Social preview.
import AppKit
import Foundation

let width: CGFloat = 1280
let height: CGFloat = 640

let colorSpace = CGColorSpaceCreateDeviceRGB()
let context = CGContext(
    data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Same diagonal gradient as the icon: deep slate → violet.
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.07, green: 0.09, blue: 0.18, alpha: 1),
        CGColor(red: 0.32, green: 0.15, blue: 0.75, alpha: 1),
    ] as CFArray,
    locations: [0, 1])!
context.drawLinearGradient(
    gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: width, y: height), options: [])

// Waveform on the left half, vertically centered — the icon's 7 bars.
let heights: [CGFloat] = [0.22, 0.40, 0.62, 0.86, 0.55, 0.34, 0.20]
let barWidth: CGFloat = 34
let gap: CGFloat = 26
let maxBarHeight: CGFloat = 300
var x: CGFloat = 120
for (index, factor) in heights.enumerated() {
    let barHeight = maxBarHeight * factor
    let bar = CGRect(x: x, y: (height - barHeight) / 2, width: barWidth, height: barHeight)
    let path = CGPath(
        roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
    context.setFillColor(
        index == 3
            ? CGColor(red: 0.99, green: 0.75, blue: 0.28, alpha: 1)
            : CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
    context.addPath(path)
    context.fillPath()
    x += barWidth + gap
}

// Text block on the right: wordmark, tagline, install command.
let graphics = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.current = graphics

func draw(_ text: String, font: NSFont, color: NSColor, at point: CGPoint) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    NSAttributedString(string: text, attributes: attributes).draw(at: point)
}

let textX: CGFloat = 610
draw(
    "Portavoz",
    font: .systemFont(ofSize: 96, weight: .bold),
    color: .white,
    at: CGPoint(x: textX, y: 380))
draw(
    "Knows who said what — locally.",
    font: .systemFont(ofSize: 34, weight: .medium),
    color: NSColor(white: 1, alpha: 0.92),
    at: CGPoint(x: textX, y: 320))
draw(
    "Live transcription · on-device voices · local summaries",
    font: .systemFont(ofSize: 24, weight: .regular),
    color: NSColor(white: 1, alpha: 0.72),
    at: CGPoint(x: textX, y: 268))

// Install command in a soft pill, monospaced.
let command = "brew install --cask portavoz"
let commandFont = NSFont.monospacedSystemFont(ofSize: 24, weight: .medium)
let commandSize = NSAttributedString(
    string: command, attributes: [.font: commandFont]).size()
let pill = CGRect(
    x: textX, y: 180, width: commandSize.width + 48, height: commandSize.height + 24)
context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
context.addPath(CGPath(
    roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2,
    transform: nil))
context.fillPath()
draw(
    command, font: commandFont,
    color: NSColor(red: 0.99, green: 0.75, blue: 0.28, alpha: 1),
    at: CGPoint(x: pill.minX + 24, y: pill.minY + 12))

NSGraphicsContext.current = nil

let image = context.makeImage()!
let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("assets/social-preview.png")
let rep = NSBitmapImageRep(cgImage: image)
try rep.representation(using: .png, properties: [:])!.write(to: destination)
print("OK → assets/social-preview.png (\(Int(width))×\(Int(height)))")
