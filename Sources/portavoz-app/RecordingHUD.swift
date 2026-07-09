import AppKit
import PortavozCore
import SwiftUI

/// Floating compact HUD for recording (GAPS #4): a small always-on-top,
/// NON-ACTIVATING panel with the timer, the latest caption, the mic meter
/// and Stop — recording stays visible without the full window covering the
/// meeting you're attending. Clicks never steal focus from Zoom/Meet.
@MainActor
final class RecordingHUDController {
    private var panel: NSPanel?

    var isVisible: Bool { panel != nil }

    func show(content: some View) {
        guard panel == nil else { return }
        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 88),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: AnyView(content))
        // Top-right corner of the main screen, under the menu bar.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 416, y: frame.maxY - 104))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Borderless panels refuse key status by default; the HUD needs it so its
/// buttons land clicks (the `.nonactivatingPanel` mask still keeps the
/// meeting app frontmost).
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The HUD's content: timer + latest caption + mini mic meter + expand/stop.
/// Auto-expands back to the window as soon as the recording leaves the
/// `.recording` phase, so processing/errors are never hidden in a mini panel.
struct RecordingHUDView: View {
    let controller: RecordingController
    let onExpand: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: controller.startedAt, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince(controller.startedAt))
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .opacity(elapsed.isMultiple(of: 2) ? 1 : 0.35)
                    Text(String(format: "%02d:%02d", max(0, elapsed) / 60, max(0, elapsed) % 60))
                        .font(.callout.monospacedDigit().weight(.medium))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.captions.last?.text ?? "…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                hudMeter
            }
            Button(action: onExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help("Back to the full window")
            Button(action: onStop) {
                Image(systemName: "stop.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Stop recording")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 400)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: controller.phase) { _, phase in
            if phase != .recording { onExpand() }
        }
    }

    private var hudMeter: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            GeometryReader { geometry in
                Capsule()
                    .fill(controller.micLevelLow ? Color.orange : Color.green)
                    .frame(width: geometry.size.width * hudMeterFraction)
            }
        }
        .frame(width: 90, height: 4)
    }

    private var hudMeterFraction: CGFloat {
        let level = controller.micLevel
        guard level > 0.0001 else { return 0 }
        let decibels = 20 * log10(level)
        return CGFloat(max(0, min(1, (Double(decibels) + 60) / 60)))
    }
}
