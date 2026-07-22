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

    private static let width: CGFloat = 400
    private static let baseHeight: CGFloat = 88
    private static let maxHeight: CGFloat = 220

    func show(content: some View) {
        guard panel == nil else { return }
        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.baseHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        // Top-right corner of the main screen, under the menu bar.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(x: frame.maxX - Self.width - 16, y: frame.maxY - Self.baseHeight - 16))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Resizes the HUD to fit its content, growing toward whichever side has
    /// room: parked in the lower half of the screen it grows UPWARD (bottom
    /// edge fixed); up near the menu bar it grows downward (top edge fixed).
    /// Either way the newest caption stays visible and the panel is clamped
    /// inside the visible frame. Clamped in height so a long caption can't run
    /// off-screen.
    func setContentHeight(_ height: CGFloat) {
        guard let panel else { return }
        let clamped = max(Self.baseHeight, min(Self.maxHeight, height))
        guard abs(clamped - panel.frame.height) > 0.5 else { return }
        var frame = panel.frame
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? frame
        // AppKit's y grows upward, so a smaller midY means the lower half.
        if frame.midY < visible.midY {
            frame.size.height = clamped  // grow up: bottom (origin.y) stays put
        } else {
            let top = frame.maxY
            frame.size.height = clamped
            frame.origin.y = top - clamped  // grow down: top stays put
        }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        panel.setFrame(frame, display: true, animate: false)
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
    /// The panel resizes to this content height so a long, unbroken caption
    /// grows the HUD (up to a cap) instead of clipping — see `captionLineCap`.
    var onHeight: (CGFloat) -> Void = { _ in }

    /// How many lines a single ongoing utterance may grow the HUD to before it
    /// stops growing and shows only the newest lines (head truncation). A pause
    /// or a new speaker starts a fresh coalesced line, resetting it to one.
    private let captionLineCap = 6

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
                    // Grow with the current utterance, but keep the NEWEST words
                    // visible: past the cap, truncate the head (what was said
                    // earliest), never the tail (what's being said now).
                    .lineLimit(captionLineCap)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                hudMeter
                if controller.systemCaptureHealth != .healthy {
                    Label {
                        Text(hudCaptureHealthMessage)
                    } icon: {
                        Image(systemName: hudCaptureHealthIcon)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(hudCaptureHealthColor)
                    .accessibilityIdentifier("recording-hud-system-capture-health")
                }
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
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .background(
            GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.size.height) { _, height in onHeight(height) }
                    .onAppear { onHeight(geo.size.height) }
            }
        )
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

    private var hudCaptureHealthMessage: String {
        if controller.shouldSuggestStopForRemoteOutage {
            return L10n.text("Call may have ended — stop recording")
        }
        return L10n.text(controller.systemCaptureHealth.compactStatusMessageKey)
    }

    private var hudCaptureHealthIcon: String {
        controller.systemCaptureHealth == .recovered
            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var hudCaptureHealthColor: Color {
        controller.systemCaptureHealth == .recovered ? .green : .orange
    }
}
