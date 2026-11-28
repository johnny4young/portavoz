import AppKit
import Observation

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

/// The elapsed time beside the recording mark, ticked once a second from
/// outside the label: a timeline inside a menu-bar label restarts with every
/// redraw and keeps the main thread busy.
@MainActor
@Observable
final class MenuBarElapsedClock {
    private(set) var text: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Ticks while `startedAt` is given; nil stops and clears it.
    func follow(_ startedAt: (@MainActor () -> Date?)?) {
        task?.cancel()
        task = nil
        guard let startedAt else {
            text = nil
            return
        }
        tick(startedAt)
        task = Task { [weak self] in
            while !Task.isCancelled {
                // Wake on the next whole second of the recording.
                let elapsed = startedAt().map { Date().timeIntervalSince($0) } ?? 0
                try? await Task.sleep(for: .seconds(1 - elapsed.truncatingRemainder(dividingBy: 1)))
                guard !Task.isCancelled else { return }
                self?.tick(startedAt)
            }
        }
    }

    private func tick(_ startedAt: () -> Date?) {
        guard let start = startedAt() else { return }
        let next = ClockFormat.mmss(Date().timeIntervalSince(start), truncating: true)
        if next != text { text = next }
    }
}
